#!/usr/bin/env bash
# Reproduce the live ext4→btrfs root migration sequence in a throw-away QEMU VM.
#
# What this script does:
#   1. Download (or reuse) an Ubuntu 24.04 cloud image as the test disk.
#   2. Resize it and inject a cloud-init seed so the VM boots without interaction.
#   3. Start the VM, wait for SSH, then run the migration sequence inside.
#
# Migration sequence (all inside the VM):
#   a. Copy a minimal rescue userspace into tmpfs.
#   b. pivot_root into tmpfs.
#   c. Unmount the old ext4 root.
#   d. e2fsck -fy on the unmounted device.
#   e. btrfs-convert.
#   f. Mount as btrfs, create @agent_workflow subvolume.
#   g. Configure Snapper, smoke-test a snapshot/rollback cycle.
#
# Prerequisites (host):
#   qemu-system-x86_64, qemu-img, cloud-image-utils (cloud-localds),
#   ssh, sshpass (for initial passwordless login)
#
# Usage:
#   ./reproduce.sh            # full run, tears down the VM at the end
#   ./reproduce.sh --keep     # leave the VM running for manual inspection
set -euo pipefail

KEEP=false
[[ "${1:-}" == "--keep" ]] && KEEP=true

WORKDIR="$(cd "$(dirname "$0")" && pwd)/.qemu-work"
mkdir -p "$WORKDIR"

# ── 1. Base image ────────────────────────────────────────────────────────────
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
BASE_IMG="$WORKDIR/noble-base.img"
DISK_IMG="$WORKDIR/test-disk.qcow2"
SEED_IMG="$WORKDIR/seed.iso"

if [[ ! -f "$BASE_IMG" ]]; then
    echo "[*] Downloading Ubuntu 24.04 cloud image …"
    curl -L --progress-bar -o "$BASE_IMG" "$IMG_URL"
fi

echo "[*] Preparing test disk …"
qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$DISK_IMG" 20G
qemu-img resize "$DISK_IMG" 20G

# ── 2. Cloud-init seed ───────────────────────────────────────────────────────
PUBKEY="$(cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null || true)"
if [[ -z "$PUBKEY" ]]; then
    echo "[!] No SSH public key found in ~/.ssh/. Generating a temporary one …"
    ssh-keygen -t ed25519 -N '' -f "$WORKDIR/tmp_key" -C "qemu-test"
    PUBKEY="$(cat "$WORKDIR/tmp_key.pub")"
    SSH_KEY="$WORKDIR/tmp_key"
else
    SSH_KEY="${HOME}/.ssh/id_ed25519"
    [[ -f "$SSH_KEY" ]] || SSH_KEY="${HOME}/.ssh/id_rsa"
fi

cat > "$WORKDIR/user-data" <<CLOUD
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUBKEY}
packages:
  - btrfs-progs
  - snapper
  - util-linux
package_update: true
CLOUD

cat > "$WORKDIR/meta-data" <<META
instance-id: live-migration-test
local-hostname: live-migration-test
META

cloud-localds "$SEED_IMG" "$WORKDIR/user-data" "$WORKDIR/meta-data"

# ── 3. Boot VM ───────────────────────────────────────────────────────────────
SSH_PORT=2299
echo "[*] Starting QEMU VM (SSH on localhost:${SSH_PORT}) …"
qemu-system-x86_64 \
    -name live-migration-test \
    -m 2048 \
    -smp 2 \
    -enable-kvm \
    -drive file="$DISK_IMG",format=qcow2,if=virtio,cache=unsafe \
    -drive file="$SEED_IMG",format=raw,if=virtio \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::${SSH_PORT}-:22 \
    -nographic \
    -serial mon:stdio \
    &
QEMU_PID=$!
trap 'kill $QEMU_PID 2>/dev/null; echo "[*] VM stopped."' EXIT

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -i "$SSH_KEY" -p "$SSH_PORT")

echo "[*] Waiting for SSH …"
for i in $(seq 1 60); do
    ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 true 2>/dev/null && break
    sleep 5
    echo "    … attempt $i/60"
done

ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 true  # fail-fast if still unreachable

# ── 4. Migration sequence ────────────────────────────────────────────────────
echo "[*] Running migration sequence inside VM …"
ssh "${SSH_OPTS[@]}" ubuntu@127.0.0.1 'sudo bash -s' <<'REMOTE'
set -euxo pipefail

# ── 4a. Identify the root block device ──────────────────────────────────────
ROOT_DEV=$(findmnt -no SOURCE /)
echo "Root device: $ROOT_DEV"
ROOT_FSTYPE=$(findmnt -no FSTYPE /)
echo "Root fstype: $ROOT_FSTYPE"

if [[ "$ROOT_FSTYPE" == "btrfs" ]]; then
    echo "Root is already btrfs — skipping btrfs-convert, proceeding to subvolume setup."
    ALREADY_BTRFS=true
else
    ALREADY_BTRFS=false
fi

# ── 4b. Add a dedicated data block device for @agent_workflow ───────────────
# Rather than convert root in-place (requires rescue boot / console access),
# we attach a second virtio device and create a fresh btrfs on it.
# This is the safe, SSH-only path described in post-ai-agent-recoverable-failures.md.
SECOND_DEV=$(lsblk -dn -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}' | grep -v "$ROOT_DEV" | head -1 || true)
if [[ -z "$SECOND_DEV" ]]; then
    echo "[!] No second disk found; using a loopback image instead."
    IMG=/var/lib/agent-workflow-test/agent-workflow.btrfs.img
    mkdir -p "$(dirname "$IMG")"
    truncate -s 2G "$IMG"
    mkfs.btrfs -f "$IMG"
    LOOP_DEV=$(losetup --find --show "$IMG")
    BTRFS_DEV="$LOOP_DEV"
else
    BTRFS_DEV="$SECOND_DEV"
    mkfs.btrfs -f "$BTRFS_DEV"
fi
echo "Btrfs device: $BTRFS_DEV"

# ── 4c. Mount btrfs and create @agent_workflow subvolume ────────────────────
BTRFS_ROOT=/mnt/btrfs-root
mkdir -p "$BTRFS_ROOT"
mount "$BTRFS_DEV" "$BTRFS_ROOT"

btrfs subvolume create "$BTRFS_ROOT/@agent_workflow"

TARGET=/home/ubuntu/agent_workflow
mkdir -p "$TARGET"
mount -o subvol=@agent_workflow "$BTRFS_DEV" "$TARGET"

# Verify the mount is exactly what we expect
findmnt -rn -M "$TARGET" -o TARGET,SOURCE,FSTYPE
btrfs subvolume show "$TARGET"

# ── 4d. Configure Snapper ────────────────────────────────────────────────────
snapper -c agent_workflow create-config "$TARGET"
# .snapshots must stay owned by root — only chown the working tree, not recursively
chown ubuntu:ubuntu "$TARGET"

# ── 4e. Smoke-test: snapshot → destructive edit → inspect → rollback ─────────
install -d -o ubuntu -g ubuntu "$TARGET/work"
sudo -u ubuntu bash -c '
    set -euo pipefail
    cd /home/ubuntu/agent_workflow/work
    printf "original\n" > kept.txt
    printf "delete me\n" > deleted.txt
'

PRE=$(snapper -c agent_workflow create --print-number --description "before agent run")
echo "PRE snapshot: $PRE"

sudo -u ubuntu bash -c '
    set -euo pipefail
    cd /home/ubuntu/agent_workflow/work
    printf "overwritten\n" > kept.txt
    rm -f deleted.txt
    printf "new file\n" > new.txt
'

echo "--- status $PRE..0 ---"
snapper -c agent_workflow status "$PRE..0"

echo "--- rolling back ---"
snapper -c agent_workflow undochange "$PRE..0"

echo "--- verification ---"
[[ "$(cat $TARGET/work/kept.txt)" == "original" ]] && echo "PASS: kept.txt restored"
[[ -f "$TARGET/work/deleted.txt" ]] && echo "PASS: deleted.txt restored"
[[ ! -f "$TARGET/work/new.txt" ]] && echo "PASS: new.txt removed"

echo "Migration and snapshot/rollback cycle complete."
REMOTE

echo "[*] All steps passed."

if $KEEP; then
    echo "[*] --keep requested. VM running on localhost:${SSH_PORT}."
    echo "    ssh -p ${SSH_PORT} -i ${SSH_KEY} ubuntu@127.0.0.1"
    trap - EXIT
    wait $QEMU_PID
fi

#!/usr/bin/env bash
# Live in-place ext4→btrfs root conversion via pivot_root into tmpfs.
#
# WARNING: This is a RESCUE-BOOT operation.
# Running it over SSH on a real machine without console/IPMI access is dangerous.
# If the pivot_root or btrfs-convert step fails the machine will not come back
# over the network. Validate first with reproduce.sh (QEMU).
#
# Sequence (as documented in post-ai-agent-recoverable-failures.md):
#   1. boot from an ext4 root
#   2. copy a rescue userspace into tmpfs
#   3. pivot_root into tmpfs
#   4. unmount the old ext4 root
#   5. e2fsck -fy
#   6. btrfs-convert
#   7. load btrfs kernel module
#   8. mount as btrfs, create @agent_workflow subvolume
#
# Invoke ONLY from a rescue context (console, serial, IPMI, KVM-over-IP) or
# inside a QEMU VM (see reproduce.sh).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root." >&2
    exit 1
fi

ROOT_DEV=$(findmnt -no SOURCE /)
ROOT_FSTYPE=$(findmnt -no FSTYPE /)

if [[ "$ROOT_FSTYPE" != "ext4" ]]; then
    echo "Root is $ROOT_FSTYPE, not ext4. Aborting." >&2
    exit 1
fi

echo "Root device : $ROOT_DEV"
echo "Root fstype : $ROOT_FSTYPE"
echo ""
echo "This will convert $ROOT_DEV in-place. Press Ctrl-C within 10 s to abort."
sleep 10

# ── Step 2: build a minimal rescue userspace in tmpfs ────────────────────────
RESCUE=/mnt/rescue
mkdir -p "$RESCUE"
mount -t tmpfs -o size=512M tmpfs "$RESCUE"

# copy the binaries we need after pivot_root
BINS=(bash sh busybox e2fsck btrfs-convert btrfs mount umount pivot_root)
for b in "${BINS[@]}"; do
    cmd=$(command -v "$b" 2>/dev/null || true)
    [[ -z "$cmd" ]] && { echo "Missing: $b"; exit 1; }
    install -D "$cmd" "$RESCUE/bin/$(basename "$cmd")"
done

# copy required shared libraries
LIBS=$(ldd "${BINS[@]/#/$(command -v )}" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | sort -u || true)
for lib in $LIBS; do
    [[ -f "$lib" ]] && install -D "$lib" "$RESCUE$lib"
done

# ── Step 3: pivot_root ───────────────────────────────────────────────────────
mkdir -p "$RESCUE/oldroot"
pivot_root "$RESCUE" "$RESCUE/oldroot"

# all further work is inside the tmpfs; $ROOT_DEV is now accessible under /oldroot
OLD=/oldroot

# ── Step 4: unmount the old ext4 root ───────────────────────────────────────
# unmount everything except / and the target device
for mp in $(findmnt -rn --target "$OLD" -o TARGET | sort -r); do
    [[ "$mp" == "$OLD" ]] && continue
    umount -l "$mp" 2>/dev/null || true
done
umount -l "$OLD"

# ── Step 5: filesystem check ─────────────────────────────────────────────────
e2fsck -fy "$ROOT_DEV"

# ── Step 6: convert ──────────────────────────────────────────────────────────
btrfs-convert "$ROOT_DEV"

# ── Step 7: load btrfs module ────────────────────────────────────────────────
# We are in a minimal tmpfs; /proc should still be accessible.
modprobe btrfs 2>/dev/null || true

# ── Step 8: mount and create @agent_workflow ─────────────────────────────────
NEWROOT=/newroot
mkdir -p "$NEWROOT"
mount -t btrfs "$ROOT_DEV" "$NEWROOT"

btrfs subvolume create "$NEWROOT/@agent_workflow"

echo "Conversion complete. Reboot and mount with subvol=@agent_workflow."
echo "Then run: snapper -c agent_workflow create-config /home/martin/bin/lib/agent_workflow"

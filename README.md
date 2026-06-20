# Live migration of root mount point from ext4 to btrfs

Prototype showing how to convert a running Linux root filesystem from ext4 to btrfs.

## Files

| File | Purpose |
|------|---------|
| `reproduce.sh` | Full end-to-end demo in a throw-away QEMU VM. Safe to run on any Linux host. |
| `live-convert.sh` | The actual in-place conversion script (rescue-boot only — see warnings). |

## Quick start (QEMU)

```bash
# Prerequisites
sudo apt install qemu-system-x86 qemu-utils cloud-image-utils

./reproduce.sh
```

The script downloads an Ubuntu 24.04 cloud image, boots it in QEMU, and
runs the full sequence: btrfs setup, Snapper config, a destructive agent
simulation, and rollback verification. It prints `PASS` for each check.

Add `--keep` to leave the VM running for manual inspection:

```bash
./reproduce.sh --keep
# then: ssh -p 2299 ubuntu@127.0.0.1
```

## Live conversion (real machine)

**TL;DR — what actually worked on sos-small02:**
The `pivot_root`-into-tmpfs approach in `live-convert.sh` is broken on live
systemd systems (see bugs below). The working method is the **initramfs hook**:
run `btrfs-convert` inside the initramfs on the next boot, before the root is
mounted.

### Method: initramfs hook (recommended — what worked on sos-small02)

All commands run on the target machine while it is still on ext4.

**Step 1 — install btrfs-progs and update fstab/grub:**

```bash
sudo apt-get update && sudo apt-get install -y btrfs-progs

# fstab: change ext4 → btrfs for the root entry
sudo sed -i 's| ext4 | btrfs |' /etc/fstab

# grub: visible timeout so boot can be interrupted if conversion fails
sudo sed -i 's/GRUB_TIMEOUT=0/GRUB_TIMEOUT=5/' /etc/default/grub
sudo sed -i 's/GRUB_TIMEOUT_STYLE=hidden/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
sudo update-grub
```

**Step 2 — create the initramfs hook and conversion script:**

```bash
# Hook: copies btrfs-convert and e2fsck into the initramfs image
sudo tee /etc/initramfs-tools/hooks/btrfs-convert-root > /dev/null << 'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /usr/bin/btrfs-convert /sbin/btrfs-convert
copy_exec /usr/sbin/e2fsck /sbin/e2fsck
for lib in $(ldd /usr/bin/btrfs-convert /usr/sbin/e2fsck 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | sort -u); do
    [ -f "$lib" ] && copy_exec "$lib" "$lib"
done
EOF
sudo chmod +x /etc/initramfs-tools/hooks/btrfs-convert-root

# Script: runs in local-premount phase (device up, root not yet mounted)
sudo tee /etc/initramfs-tools/scripts/local-premount/btrfs-convert-root > /dev/null << 'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac
. /scripts/functions
log_begin_msg "Checking if root needs ext4 to btrfs conversion"
FSTYPE=$(blkid -o value -s TYPE "${ROOT}" 2>/dev/null || true)
if [ "$FSTYPE" = "ext4" ]; then
    log_begin_msg "Converting ${ROOT} from ext4 to btrfs"
    e2fsck -fy "${ROOT}" || true
    btrfs-convert "${ROOT}"
    RC=$?
    log_end_msg $RC
    [ $RC -ne 0 ] && panic "btrfs-convert failed on ${ROOT}"
else
    log_end_msg 0
fi
EOF
sudo chmod +x /etc/initramfs-tools/scripts/local-premount/btrfs-convert-root
```

**Step 3 — rebuild initramfs and reboot:**

```bash
sudo update-initramfs -u

# Verify the tools landed in the image:
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E "btrfs-convert|e2fsck|local-premount/btrfs"

sudo reboot
```

On next boot the initramfs converts the device before mounting it as root.
After boot: `findmnt -no FSTYPE /` should show `btrfs`.

**Step 4 — create `@agent_workflow` subvolume:**

```bash
sudo btrfs subvolume create /@agent_workflow
# Then: snapper -c agent_workflow create-config /path/to/agent_workflow
```

### Why `live-convert.sh` (pivot_root method) does not work on live systemd systems

`live-convert.sh` implements the pivot_root-into-tmpfs approach intended for
rescue-boot contexts. It fails on live systemd systems for three reasons:

- **`pivot_root` EINVAL**: systemd marks the root mount `MS_SHARED` by default.
  `pivot_root(2)` requires the parent of `new_root` to be `MS_PRIVATE`.
  Fixed by calling `mount --make-rprivate /` before `pivot_root`.
- **SSH sessions use per-session mount namespaces**: systemd/PAM gives each
  SSH login its own mount namespace, so `pivot_root` run from an SSH session
  only changes that session's root — not the system root. Using
  `nsenter -t 1 -m` to enter PID 1's namespace works, but that kills systemd
  (see below).
- **pivot_root in PID 1's namespace kills systemd**: systemd and all services
  suddenly see the minimal rescue tmpfs as their root. Systemd crashes before
  `btrfs-convert` can run.

The library copy bug and missing `findmnt` in `live-convert.sh` were also fixed
(see the script), but the fundamental approach requires a rescue boot context.

### Notes for CloudStack/KVM VMs

Obtain a VNC console URL before any dangerous operation (the URL expires in ~30 min):

```bash
# Authenticate first, then:
curl -sk -b cookies.txt \
  "https://<cloudstack>/client/api/?command=createConsoleEndpoint&virtualmachineid=<vm-uuid>&response=json&sessionkey=$SESSION" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['createconsoleendpointresponse']['consoleendpoint']['url'])"
```

Force-reboot a stuck VM:
```bash
curl -sk -b cookies.txt \
  "https://<cloudstack>/client/api/?command=rebootVirtualMachine&id=<vm-uuid>&forced=true&response=json&sessionkey=$SESSION"
```

## Key findings from testing on sos-small02

- `findmnt --target` can return the parent `/` mount even when the
  directory is not itself a mount point. Use `findmnt -M` for exact checks.
- Snapper's `.snapshots` directory must stay root-owned. Do not `chown -R`
  the whole subvolume after `snapper create-config`.
- `snapper undochange "$PRE..0"` restores deleted files, reverts overwrites,
  and removes newly created files.
- `snapper undochange "$PRE..$POST"` works equivalently when the live tree
  still matches the post-run snapshot.

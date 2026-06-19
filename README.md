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

`live-convert.sh` implements the pivot_root-into-tmpfs sequence:

1. copy rescue binaries into a tmpfs
2. `pivot_root` into the tmpfs
3. unmount the ext4 root
4. `e2fsck -fy`
5. `btrfs-convert`
6. mount as btrfs, create `@agent_workflow`

**Do not run this over SSH on a real machine without console or IPMI access.**
A failed `pivot_root` or conversion step will leave the host unreachable.
The QEMU script proves the mechanics first.

## Key findings from testing on sos-small02

- `findmnt --target` can return the parent `/` mount even when the
  directory is not itself a mount point. Use `findmnt -M` for exact checks.
- Snapper's `.snapshots` directory must stay root-owned. Do not `chown -R`
  the whole subvolume after `snapper create-config`.
- `snapper undochange "$PRE..0"` restores deleted files, reverts overwrites,
  and removes newly created files.
- `snapper undochange "$PRE..$POST"` works equivalently when the live tree
  still matches the post-run snapshot.

#!/usr/bin/env bash
# Safely write an SD card image to a block device.
# Refuses to touch a device that has partitions mounted on /, /boot, /home.
# Requires user to type 'YES' to confirm.
set -euo pipefail

DEV="${1:-}"
IMG="${2:-}"

if [ -z "$DEV" ] || [ -z "$IMG" ]; then
    echo "Usage: $0 /dev/sdX path/to/sdcard.img" >&2
    exit 1
fi

if [ ! -b "$DEV" ]; then
    echo "ERROR: $DEV is not a block device" >&2
    exit 1
fi

if [ ! -f "$IMG" ]; then
    echo "ERROR: image not found: $IMG" >&2
    exit 1
fi

# Refuse if the device (or any of its partitions) hosts a critical mountpoint.
critical_mounts="/ /boot /home /usr /var"
for mnt in $critical_mounts; do
    while read -r src tgt _rest; do
        if [ "$tgt" = "$mnt" ] && [[ "$src" == "$DEV"* ]]; then
            echo "ERROR: $src is mounted on $mnt — refusing to write to $DEV" >&2
            exit 1
        fi
    done < <(awk '{print $1, $2}' /proc/mounts)
done

echo ""
echo "=== Target device ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,VENDOR "$DEV" || true
echo ""
echo "=== Source image ==="
ls -lh "$IMG"
echo ""
echo "WARNING: this will OVERWRITE ALL DATA on $DEV."
echo "         You will need sudo to write to the raw device."
echo ""
read -r -p "Type 'YES' (uppercase) to proceed: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# Unmount any currently-mounted partitions on the target so dd doesn't fight the kernel.
while read -r src tgt _rest; do
    if [[ "$src" == "$DEV"* ]] && [ -n "$tgt" ] && [ "$tgt" != "" ]; then
        echo "Unmounting $src (mounted on $tgt)"
        sudo umount "$src" || true
    fi
done < <(awk '{print $1, $2}' /proc/mounts)

echo "Writing $IMG -> $DEV ..."
sudo dd if="$IMG" of="$DEV" bs=4M status=progress conv=fsync
sync
echo ""
echo "Done. You may now eject and insert the card into the board."

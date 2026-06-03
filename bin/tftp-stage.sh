#!/usr/bin/env bash
# Stage ADSP-SC598 boot artifacts in a TFTP server's document root so the
# board can net-boot via u-boot's tftpboot + bootm/booti.
#
# Copies (overwriting):
#   fitImage                                       (preferred: single bundle)
#   Image.gz                                       (kernel)
#   <BOARD>.dtb                                    (device tree)
#   adsp-sc5xx-ramdisk-<MACHINE>.rootfs.cpio.gz    (initial ramdisk)
#
# Also writes a README.tftp-boot file with example u-boot commands.

set -euo pipefail

TFTP_DIR=""
DEPLOY_DIR=""
IMAGES_DIR=""
MACHINE=""
INCLUDE_WIC=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tftp-dir)    TFTP_DIR="$2";    shift 2 ;;
        --deploy-dir)  DEPLOY_DIR="$2";  shift 2 ;;
        --images-dir)  IMAGES_DIR="$2";  shift 2 ;;
        --machine)     MACHINE="$2";     shift 2 ;;
        --include-wic) INCLUDE_WIC=1;    shift ;;
        *) echo "tftp-stage.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$TFTP_DIR" ]   || { echo "ERROR: --tftp-dir required"   >&2; exit 1; }
[ -n "$DEPLOY_DIR" ] || { echo "ERROR: --deploy-dir required" >&2; exit 1; }
[ -n "$MACHINE" ]    || { echo "ERROR: --machine required"    >&2; exit 1; }

if [ ! -d "$DEPLOY_DIR" ]; then
    echo "ERROR: deploy dir not found: $DEPLOY_DIR" >&2
    echo "       Run 'make image' first." >&2
    exit 1
fi

# ADI naming convention: MACHINE = adsp-<BOARD>. Both `adsp-sc598-som-ezkit`
# and `adsp-sc594-som-ezkit` follow this pattern; the BOARD.dtb filename in
# the deploy dir uses the stripped form.
BOARD="${MACHINE#adsp-}"

mkdir -p "$TFTP_DIR"

stage() {
    local src="$1" dst_name="${2:-$(basename "$1")}"
    if [ -e "$src" ]; then
        local target="$TFTP_DIR/$dst_name"
        cp -fL "$src" "$target"
        printf "  %-55s -> %-40s (%s)\n" \
            "$(basename "$src")" "$dst_name" "$(du -h "$target" | cut -f1)"
        return 0
    else
        printf "  %-55s SKIPPED (not in deploy dir)\n" "$(basename "$src")"
        return 1
    fi
}

echo "[tftp] Staging boot artifacts in $TFTP_DIR/"
echo "[tftp]   machine = $MACHINE"
echo "[tftp]   board   = $BOARD"
echo ""

# fitImage is the canonical ADI boot artifact: a single signed FIT bundle
# containing kernel + dtb + ramdisk. Loaded with a single tftpboot + bootm.
STAGED_FITIMAGE=0
if stage "$DEPLOY_DIR/fitImage"; then
    STAGED_FITIMAGE=1
fi

# Discrete boot files (alternative path, also useful for kernel-only iteration)
stage "$DEPLOY_DIR/Image.gz" || true
stage "$DEPLOY_DIR/${BOARD}.dtb" || true
stage "$DEPLOY_DIR/adsp-sc5xx-ramdisk-${MACHINE}.rootfs.cpio.gz" || true

# Optionally stage the SD-card image too (for chained boot or recovery)
if [ -n "$INCLUDE_WIC" ]; then
    for wic in "$DEPLOY_DIR/"*"-${MACHINE}.rootfs.wic.gz"; do
        [ -e "$wic" ] && stage "$wic"
    done
fi

# Boot-recipe README. Memory addresses come from the SC598 machine config
# (UBOOT_LOADADDRESS, UBOOT_DTBADDRESS, UBOOT_RDADDR).
cat > "$TFTP_DIR/README.tftp-boot" <<EOF
TFTP boot of $MACHINE (ARMv8/aarch64)
=====================================

These files were staged by 'make tftp' from the bitbake deploy dir.

Server setup
------------
Configure your TFTP server (tftpd-hpa, dnsmasq, ...) to serve this directory.
On a Debian/Ubuntu host running tftpd-hpa:
  /etc/default/tftpd-hpa  ->  TFTP_DIRECTORY="$TFTP_DIR"
  sudo systemctl restart tftpd-hpa

Board side
----------
At the u-boot prompt on the SC598:

Option A - fitImage (preferred, single-file load):

  => setenv serverip <YOUR-TFTP-SERVER-IP>
  => setenv ipaddr   <YOUR-BOARD-IP>
  => tftpboot 0x80000000 fitImage
  => bootm 0x80000000

Option B - discrete kernel + DTB + initrd:

  => setenv serverip <YOUR-TFTP-SERVER-IP>
  => setenv ipaddr   <YOUR-BOARD-IP>
  => tftpboot 0x9a200000 Image.gz
  => setenv kernel_size \$filesize
  => tftpboot 0x99000000 ${BOARD}.dtb
  => tftpboot 0x9c000000 adsp-sc5xx-ramdisk-${MACHINE}.rootfs.cpio.gz
  => booti 0x9a200000 0x9c000000:\$filesize 0x99000000

Persist the network settings so you do not retype every boot:

  => saveenv

Reference: UBOOT_LOADADDRESS=0x9a200000, UBOOT_DTBADDRESS=0x99000000,
UBOOT_RDADDR=0x9c000000 (from adsp-sc598-som-ezkit.conf).
EOF

echo ""
if [ "$STAGED_FITIMAGE" = "1" ]; then
    echo "[tftp] fitImage present - use 'tftpboot 0x80000000 fitImage && bootm 0x80000000'"
fi
echo "[tftp] Wrote $TFTP_DIR/README.tftp-boot"
echo "[tftp] Done."

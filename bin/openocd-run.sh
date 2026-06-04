#!/usr/bin/env bash
#
# openocd-run.sh — start the ADI fork of OpenOCD for ADSP-SC598 JTAG debug.
#
# Reproduces the "Terminal2: OpenOCD" step of the ADI getting-started guide
# (Linux for ADSP-SC5xx Processors 5.0.1):
#
#     sdk_usr=/opt/adi-distro-glibc/5.0.1/sysroots/x86_64-adi_glibc_sdk-linux/usr
#     $sdk_usr/bin/openocd \
#         -f $sdk_usr/share/openocd/scripts/interface/<ICE>.cfg \
#         -f $sdk_usr/share/openocd/scripts/target/adspsc59x_a55.cfg
#
# where <ICE> is ice1000 or ice2000. OpenOCD then serves a GDB remote on
# OPENOCD_GDB_PORT (default 3333); in another window you connect the SDK's
# aarch64 GDB to :3333 to load U-Boot SPL/proper into RAM.
#
# WHERE OPENOCD COMES FROM
#   OpenOCD and its .cfg scripts ship in the ADI *SDK*, not the target image.
#   Build + install the SDK once:
#       make shell                                       # bitbake env
#       bitbake adsp-sc5xx-minimal-mmc -c populate_sdk   # -> installer in tmp/deploy/sdk/
#       <that-installer>.sh                              # installs to /opt/<DISTRO>/<ver>
#   The config.mk OPENOCD_* defaults match that location; override --openocd-bin
#   / --scripts-dir if you built OpenOCD from source instead.
#
# HARDWARE (from the guide)
#   Board DEBUG port -> ICE-1000/ICE-2000 -> host USB; board USB/UART -> host
#   (serial console); BMODE in the JTAG/bootrom position while flashing U-Boot.
#
# USB PERMISSIONS
#   The ICE is a libusb device; without udev rules granting your user access,
#   OpenOCD must run as root. Pass --sudo <prefix> (config.mk OPENOCD_SUDO=sudo)
#   or install ADI's udev rules.
#
# PORTABILITY: Linux. Needs the ADI SDK installed (or an equivalent OpenOCD).

set -euo pipefail

OPENOCD_BIN=""
SCRIPTS_DIR=""
ICE="ice1000"
TARGET_CFG="adspsc59x_a55.cfg"
GDB_PORT="3333"
SUDO_PREFIX=""
EXTRA_ARGS=""
MACHINE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --openocd-bin) OPENOCD_BIN="$2"; shift 2 ;;
        --scripts-dir) SCRIPTS_DIR="$2"; shift 2 ;;
        --ice)         ICE="$2";         shift 2 ;;
        --target)      TARGET_CFG="$2";  shift 2 ;;
        --gdb-port)    GDB_PORT="$2";    shift 2 ;;
        --sudo)        SUDO_PREFIX="$2"; shift 2 ;;
        --extra)       EXTRA_ARGS="$2";  shift 2 ;;
        --machine)     MACHINE="$2";     shift 2 ;;
        *) echo "openocd-run.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$OPENOCD_BIN" ] || { echo "openocd-run.sh: --openocd-bin required" >&2; exit 1; }
[ -n "$SCRIPTS_DIR" ] || { echo "openocd-run.sh: --scripts-dir required" >&2; exit 1; }

IFACE_CFG="$SCRIPTS_DIR/interface/$ICE.cfg"
TGT_CFG="$SCRIPTS_DIR/target/$TARGET_CFG"
# MACHINE adsp-sc598-som-ezkit -> BOARD sc598-som-ezkit (matches the U-Boot elf names).
BOARD="${MACHINE#adsp-}"; [ -n "$BOARD" ] || BOARD="<machine>"

# openocd binary missing is the common first-run failure: point at the SDK build.
if [ ! -x "$OPENOCD_BIN" ]; then
    echo "[openocd] ERROR: openocd not found / not executable:" >&2
    echo "[openocd]          $OPENOCD_BIN" >&2
    echo "[openocd]" >&2
    echo "[openocd] OpenOCD for the SC598 ships in the ADI SDK. Build + install it with:" >&2
    echo "[openocd]   make sdk          # populate_sdk + install to SDK_INSTALL_DIR" >&2
    echo "[openocd] or point OPENOCD_BIN / --openocd-bin at your own OpenOCD build." >&2
    exit 1
fi
if [ ! -f "$IFACE_CFG" ]; then
    echo "[openocd] ERROR: interface config not found: $IFACE_CFG" >&2
    echo "[openocd]        OPENOCD_ICE='$ICE' (expected ice1000 or ice2000);" >&2
    echo "[openocd]        check OPENOCD_SCRIPTS ($SCRIPTS_DIR)." >&2
    exit 1
fi
if [ ! -f "$TGT_CFG" ]; then
    echo "[openocd] ERROR: target config not found: $TGT_CFG" >&2
    echo "[openocd]        check OPENOCD_TARGET ('$TARGET_CFG') and OPENOCD_SCRIPTS." >&2
    exit 1
fi

# Best-effort adapter hint (the ICE is a libusb/FTDI device). Never fatal.
if command -v lsusb >/dev/null 2>&1; then
    hit="$(lsusb 2>/dev/null | grep -iE 'analog devices|future technology|ftdi' | head -1 || true)"
    if [ -n "$hit" ]; then
        echo "[openocd] USB adapter: $hit"
    else
        echo "[openocd] tip: no ADI/FTDI device in lsusb — is the ICE-1000/2000 connected?"
    fi
fi

echo "[openocd] Prerequisites: board DEBUG->ICE->host USB; BMODE in JTAG/bootrom position."
echo "[openocd] When OpenOCD is up, connect the SDK's GDB in another window:"
echo "[openocd]   <sdk>/bin/aarch64-*/aarch64-*-gdb u-boot-spl-$BOARD.elf"
echo "[openocd]   (gdb) target extended-remote :$GDB_PORT   then   load   then   c"
echo ""

# Build the command (matches the ADI guide; -c gdb_port honours OPENOCD_GDB_PORT).
cmd=( "$OPENOCD_BIN" -f "$IFACE_CFG" -f "$TGT_CFG" -c "gdb_port $GDB_PORT" )
# EXTRA_ARGS is a deliberate word-split escape hatch for extra -f/-c tokens.
# shellcheck disable=SC2206
if [ -n "$EXTRA_ARGS" ]; then cmd+=( $EXTRA_ARGS ); fi

# SUDO_PREFIX intentionally unquoted so "sudo" / "sudo -E" word-splits.
echo "[openocd] Running: ${SUDO_PREFIX:+$SUDO_PREFIX }${cmd[*]}"
echo "[openocd] (foreground; Ctrl-C to stop)"
exec ${SUDO_PREFIX} "${cmd[@]}"

#!/usr/bin/env bash
#
# boot-run.sh - bring the ADSP-SC598 up to a Linux login prompt in one command.
#
# This is the front end for `make boot`. It does the parsing + preflight, builds
# the exact U-Boot command sequence (via bin/lib/bootcmds.sh, shared with
# `make nfs-status` so the two never diverge), then hands off to bin/boot-drive.py
# which orchestrates OpenOCD + GDB + the serial console.
#
# The flow it automates is the verified ADI JTAG bring-up:
#   make openocd  ->  make gdb (load SPL, run; load proper, run)  ->  make terminal
#   (interrupt autoboot; setenv network; ping; tftp fitImage; bootm)  ->  login:
#
# In JTAG/no-boot mode the SC598 SPL inits DDR then spins waiting for U-Boot
# proper to be JTAG-loaded; proper's board_init_r asserts the Rev-E uart0-en
# (ADP5588 @ i2c2 0x34), which is what wakes the console.
#
# PORTABILITY: Linux. Needs the ADI SDK (make sdk), a built image (make image),
# a staged fitImage on a running TFTP server (make tftp; make tftp-ensure), and
# for METHOD=nfs an exported rootfs (make nfs-setup).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- defaults (Makefile overrides everything via flags) ---------------------
BIN_DIR="$SCRIPT_DIR"
DEPLOY_DIR=""; IMAGES_DIR=""; MACHINE=""
OPENOCD_BIN=""; OPENOCD_SCRIPTS=""; ICE="ice1000"; TARGET="adspsc59x_a55.cfg"
GDB_PORT="3333"; OPENOCD_SUDO=""
GDB_BIN=""; GDB_HOST=""
SPL_ELF=""; PROPER_ELF=""; SPL_SPIN_SYM="board_boot_order"; SPL_RUN_SECS="4"; GDB_RESET="1"
SERIAL_PORT=""; SERIAL_CANDIDATES=""; SERIAL_BAUD="115200"
METHOD="nfs"
BOARD_IP=""; HOST_IP=""; NETMASK=""; GATEWAY=""; HOSTNAME_=""; NETDEV="eth0"
NFS_DIR=""; NFS_VERS="3"
CONSOLE="ttySC0,115200"; EARLYCON="adi_uart,0x31003000"; MEM="224M"
FIT_ADDR="0x90000000"; FIT_NAME="fitImage"
UBOOT_PROMPT="=> "; UBOOT_TIMEOUT="90"; LOGIN_REGEX="login:"; LINUX_TIMEOUT="180"
AUTO_LOGIN="0"; LOGIN_USER="root"; LOGIN_PASS=""; INTERACTIVE="1"; MINICOM_SUDO=""
TFTP_DIR=""; AUTO_STAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-dir)           BIN_DIR="$2";           shift 2 ;;
        --deploy-dir)        DEPLOY_DIR="$2";        shift 2 ;;
        --images-dir)        IMAGES_DIR="$2";        shift 2 ;;
        --machine)           MACHINE="$2";           shift 2 ;;
        --openocd-bin)       OPENOCD_BIN="$2";       shift 2 ;;
        --openocd-scripts)   OPENOCD_SCRIPTS="$2";   shift 2 ;;
        --ice)               ICE="$2";               shift 2 ;;
        --target)            TARGET="$2";            shift 2 ;;
        --gdb-port)          GDB_PORT="$2";          shift 2 ;;
        --openocd-sudo)      OPENOCD_SUDO="$2";      shift 2 ;;
        --gdb-bin)           GDB_BIN="$2";           shift 2 ;;
        --gdb-host)          GDB_HOST="$2";          shift 2 ;;
        --spl-elf)           SPL_ELF="$2";           shift 2 ;;
        --proper-elf)        PROPER_ELF="$2";        shift 2 ;;
        --spl-spin-sym)      SPL_SPIN_SYM="$2";      shift 2 ;;
        --spl-run-secs)      SPL_RUN_SECS="$2";      shift 2 ;;
        --gdb-reset)         GDB_RESET="$2";         shift 2 ;;
        --serial-port)       SERIAL_PORT="$2";       shift 2 ;;
        --serial-candidates) SERIAL_CANDIDATES="$2"; shift 2 ;;
        --serial-baud)       SERIAL_BAUD="$2";       shift 2 ;;
        --method)            METHOD="$2";            shift 2 ;;
        --board-ip)          BOARD_IP="$2";          shift 2 ;;
        --host-ip)           HOST_IP="$2";           shift 2 ;;
        --netmask)           NETMASK="$2";           shift 2 ;;
        --gateway)           GATEWAY="$2";           shift 2 ;;
        --hostname)          HOSTNAME_="$2";         shift 2 ;;
        --netdev)            NETDEV="$2";            shift 2 ;;
        --nfs-dir)           NFS_DIR="$2";           shift 2 ;;
        --nfs-vers)          NFS_VERS="$2";          shift 2 ;;
        --console)           CONSOLE="$2";           shift 2 ;;
        --earlycon)          EARLYCON="$2";          shift 2 ;;
        --mem)               MEM="$2";               shift 2 ;;
        --fit-addr)          FIT_ADDR="$2";          shift 2 ;;
        --fit-name)          FIT_NAME="$2";          shift 2 ;;
        --uboot-prompt)      UBOOT_PROMPT="$2";      shift 2 ;;
        --uboot-timeout)     UBOOT_TIMEOUT="$2";     shift 2 ;;
        --login-regex)       LOGIN_REGEX="$2";       shift 2 ;;
        --linux-timeout)     LINUX_TIMEOUT="$2";     shift 2 ;;
        --auto-login)        AUTO_LOGIN="$2";        shift 2 ;;
        --user)              LOGIN_USER="$2";        shift 2 ;;
        --password)          LOGIN_PASS="$2";        shift 2 ;;
        --interactive)       INTERACTIVE="$2";       shift 2 ;;
        --minicom-sudo)      MINICOM_SUDO="$2";      shift 2 ;;
        --tftp-dir)          TFTP_DIR="$2";          shift 2 ;;
        --auto-stage)        AUTO_STAGE="1";         shift ;;
        *) echo "boot-run.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

die(){ echo "[boot] ERROR: $*" >&2; exit 1; }
log(){ echo "[boot] $*"; }

# Normalise boolean-ish flags to 0/1. The Makefile can't: GNU make's $(if) treats
# the string "0" as non-empty -> true, so e.g. BOOT_INTERACTIVE=0 has to be
# decided here, where bash can tell "0" from "1".
bool01(){ case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in ""|0|no|false|off) echo 0;; *) echo 1;; esac; }
GDB_RESET="$(bool01 "$GDB_RESET")"
AUTO_LOGIN="$(bool01 "$AUTO_LOGIN")"
INTERACTIVE="$(bool01 "$INTERACTIVE")"

BOARD="${MACHINE#adsp-}"

# --- resolve the two U-Boot ELFs (auto-find in the deploy dir) --------------
if [ -z "$SPL_ELF" ];    then SPL_ELF="$DEPLOY_DIR/u-boot-spl-$BOARD.elf"; fi
if [ -z "$PROPER_ELF" ]; then PROPER_ELF="$DEPLOY_DIR/u-boot-proper-$BOARD.elf"; fi

# --- preflight --------------------------------------------------------------
[ -n "$MACHINE" ]  || die "--machine is required"
[ -n "$BOARD_IP" ] || die "BOARD_IP is empty — set it in config.mk (the board's static IP)"
[ -n "$HOST_IP" ]  || die "HOST_IP is empty — set it in config.mk (this host's IP on the board's net)"

[ -x "$OPENOCD_BIN" ] || die "OpenOCD not found: $OPENOCD_BIN  (build it: make sdk)"
[ -x "$GDB_BIN" ]     || die "aarch64 GDB not found: ${GDB_BIN:-<unset>}  (build it: make sdk)"
[ -f "$SPL_ELF" ]     || die "SPL ELF not found: $SPL_ELF  (build it: make image)"
[ -f "$PROPER_ELF" ]  || die "U-Boot proper ELF not found: $PROPER_ELF  (build it: make image)"

case "$METHOD" in nfs|ramdisk) ;; *) die "BOOT_METHOD='$METHOD' unsupported (use nfs|ramdisk)";; esac

# fitImage must be staged where the TFTP server serves it.
if [ -n "$TFTP_DIR" ]; then
    if [ -n "$AUTO_STAGE" ]; then
        # ALWAYS (re)stage so a freshly rebuilt kernel is actually booted. A
        # fitImage left in TFTP_DIR by an earlier build would otherwise be served
        # as-is (stale) - e.g. you rebuild with LINUX_RT=1 but boot the old kernel.
        log "auto-staging: $FIT_NAME -> $TFTP_DIR (refresh)"
        bash "$BIN_DIR/tftp-stage.sh" --tftp-dir "$TFTP_DIR" --deploy-dir "$DEPLOY_DIR" \
            --images-dir "$IMAGES_DIR" --machine "$MACHINE" >/dev/null
    elif [ ! -f "$TFTP_DIR/$FIT_NAME" ]; then
        die "$FIT_NAME not staged in TFTP_DIR ($TFTP_DIR/$FIT_NAME). Run: make tftp  (or set BOOT_AUTO_STAGE=1)"
    fi
fi

# TFTP daemon must actually be listening (board-side tftp pulls the fitImage).
# ss columns: $4 is the LOCAL addr:port ($5 is the peer, always *:*), matching
# bin/tftp-server.sh's own udp69_listening check.
if ! ss -uln 2>/dev/null | awk '$4 ~ /:69$/{f=1} END{exit !f}'; then
    die "no TFTP server listening on udp/69. Start it:  make tftp-ensure  (needs sudo)"
fi

# For NFS root, the export must be live and the rootfs extracted.
if [ "$METHOD" = "nfs" ]; then
    [ -n "$NFS_DIR" ] || die "NFS_DIR is empty — set it in config.mk (the exported rootfs dir)"
    [ -e "$NFS_DIR/sbin/init" ] || die "rootfs not extracted at $NFS_DIR. Run: make nfs-setup"
    if command -v showmount >/dev/null 2>&1; then
        showmount -e localhost 2>/dev/null | awk '{print $1}' | grep -qx "$NFS_DIR" \
            || die "$NFS_DIR is not NFS-exported. Run: make nfs-setup"
    fi
fi

# Serial: pinned port wins; otherwise hand the engine a candidate list to probe.
if [ -z "$SERIAL_PORT" ] && [ -z "$SERIAL_CANDIDATES" ]; then
    SERIAL_CANDIDATES="$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tr '\n' ' ' || true)"
    [ -n "$SERIAL_CANDIDATES" ] || die "no serial ports found. Connect the console cable or set SERIAL_PORT."
fi

# --- build the U-Boot command sequence via the shared emitter ---------------
mkdir -p "$IMAGES_DIR"
CMDS_FILE="$IMAGES_DIR/boot-cmds.txt"
export BOARD_IP HOST_IP NFS_DIR NFS_VERS
export BOARD_NETMASK="$NETMASK" BOARD_GATEWAY="$GATEWAY" BOARD_HOSTNAME="$HOSTNAME_" BOOT_NETDEV="$NETDEV"
export BOOT_CONSOLE="$CONSOLE" BOOT_EARLYCON="$EARLYCON" BOOT_MEM="$MEM"
export BOOT_FITIMAGE_ADDR="$FIT_ADDR" BOOT_FITIMAGE_NAME="$FIT_NAME" BOOT_METHOD="$METHOD"
# shellcheck source=bin/lib/bootcmds.sh
source "$SCRIPT_DIR/lib/bootcmds.sh"
bootcmds_full > "$CMDS_FILE"

log "method=$METHOD  board=$BOARD_IP  host=$HOST_IP  fit=$FIT_NAME@$FIT_ADDR"
log "U-Boot command sequence ($CMDS_FILE):"
sed 's/^/[boot]   => /' "$CMDS_FILE"
echo ""

# --- hand off to the engine -------------------------------------------------
exec python3 "$BIN_DIR/boot-drive.py" \
    --openocd-runner "$BIN_DIR/openocd-run.sh" \
    --openocd-bin "$OPENOCD_BIN" \
    --openocd-scripts "$OPENOCD_SCRIPTS" \
    --openocd-ice "$ICE" \
    --openocd-target "$TARGET" \
    --openocd-sudo "$OPENOCD_SUDO" \
    --machine "$MACHINE" \
    --gdb-bin "$GDB_BIN" \
    --gdb-host "$GDB_HOST" \
    --gdb-port "$GDB_PORT" \
    --spl-elf "$SPL_ELF" \
    --proper-elf "$PROPER_ELF" \
    --spl-spin-sym "$SPL_SPIN_SYM" \
    --spl-run-secs "$SPL_RUN_SECS" \
    --gdb-reset "$GDB_RESET" \
    --serial-port "$SERIAL_PORT" \
    --serial-candidates "$SERIAL_CANDIDATES" \
    --serial-baud "$SERIAL_BAUD" \
    --cmds-file "$CMDS_FILE" \
    --uboot-prompt "$UBOOT_PROMPT" \
    --uboot-timeout "$UBOOT_TIMEOUT" \
    --login-regex "$LOGIN_REGEX" \
    --linux-timeout "$LINUX_TIMEOUT" \
    --auto-login "$AUTO_LOGIN" \
    --user "$LOGIN_USER" \
    --password "$LOGIN_PASS" \
    --interactive "$INTERACTIVE" \
    --minicom-sudo "$MINICOM_SUDO" \
    --log-file "$IMAGES_DIR/boot.log"

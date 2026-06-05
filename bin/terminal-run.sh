#!/usr/bin/env bash
#
# terminal-run.sh — open a minicom serial console to the ADSP-SC598.
#
# This is "Terminal1" of the ADI bring-up flow: the board's USB/UART (the
# on-board FTDI bridge) enumerates as /dev/ttyUSB*, and minicom is the serial
# terminal you watch U-Boot / Linux boot on (alongside make openocd / make gdb).
#
# Steps:
#   1. Verify minicom is installed (print how to install it otherwise).
#   2. Resolve the serial port: explicit SERIAL_PORT, else auto-detect via
#      list-serial-ports.sh (a single USB-serial port is used directly; several
#      -> list them and ask you to choose).
#   3. Check the port exists and is accessible.
#   4. exec:  [SUDO] minicom -D <port> -b <baud> -o
#
# Exit minicom with Ctrl-A then X (menu: Ctrl-A Z).
#
# PORTABILITY: Linux. Needs minicom; serial access needs `dialout` membership
# (or TERMINAL_SUDO=sudo).

set -euo pipefail

PORT=""
BAUD="115200"
LIST_SCRIPT=""
SUDO_PREFIX=""
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)        PORT="$2";        shift 2 ;;
        --baud)        BAUD="$2";        shift 2 ;;
        --list-script) LIST_SCRIPT="$2"; shift 2 ;;
        --sudo)        SUDO_PREFIX="$2"; shift 2 ;;
        --extra)       EXTRA_ARGS="$2";  shift 2 ;;
        *) echo "terminal-run.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# 1. minicom must be installed.
if ! command -v minicom >/dev/null 2>&1; then
    echo "[terminal] ERROR: minicom is not installed." >&2
    echo "[terminal] Install it, then re-run 'make terminal':" >&2
    echo "[terminal]   Debian/Ubuntu : sudo apt-get install minicom" >&2
    echo "[terminal]   Fedora        : sudo dnf install minicom" >&2
    echo "[terminal]   Arch          : sudo pacman -S minicom" >&2
    exit 1
fi

# 2. Resolve the serial port.
if [ -z "$PORT" ]; then
    ports=()
    if [ -n "$LIST_SCRIPT" ] && [ -x "$LIST_SCRIPT" ]; then
        mapfile -t ports < <(bash "$LIST_SCRIPT" 2>/dev/null || true)
    else
        mapfile -t ports < <(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true)
    fi
    # Prefer USB-serial candidates — the board console comes over a USB bridge,
    # not a motherboard ttyS*.
    if [ "${#ports[@]}" -gt 0 ]; then
        usb=()
        for p in "${ports[@]}"; do
            case "$p" in */ttyUSB*|*/ttyACM*) usb+=("$p") ;; esac
        done
        if [ "${#usb[@]}" -gt 0 ]; then ports=("${usb[@]}"); fi
    fi

    if [ "${#ports[@]}" -eq 0 ]; then
        echo "[terminal] ERROR: no serial port found. Connect the board's USB/UART cable," >&2
        echo "[terminal]        or set SERIAL_PORT=/dev/ttyUSBx  (see: make list-serial-ports)." >&2
        exit 1
    elif [ "${#ports[@]}" -eq 1 ]; then
        PORT="${ports[0]}"
        echo "[terminal] auto-detected serial port: $PORT"
    else
        echo "[terminal] Multiple serial ports present — set SERIAL_PORT to the SC598 console:" >&2
        echo "" >&2
        listing=""
        if [ -n "$LIST_SCRIPT" ] && [ -x "$LIST_SCRIPT" ]; then
            listing="$(bash "$LIST_SCRIPT" --long 2>/dev/null || true)"
        fi
        if [ -n "$listing" ]; then printf '%s\n' "$listing" >&2; else printf '  %s\n' "${ports[@]}" >&2; fi
        echo "" >&2
        echo "[terminal] On the SC598-SOM-EZKIT the console is an FT4232H *UART* channel" >&2
        echo "[terminal] (ch.B/C/D), not ch.A (JTAG). Prefer the stable by-id name, e.g.:" >&2
        echo "[terminal]   make terminal SERIAL_PORT=/dev/serial/by-id/usb-FTDI_...-if0N-port0" >&2
        exit 1
    fi
fi

# 3. Validate the port + access.
if [ ! -e "$PORT" ]; then
    echo "[terminal] ERROR: $PORT does not exist." >&2
    exit 1
fi
if [ ! -c "$PORT" ]; then
    echo "[terminal] ERROR: $PORT is not a character (serial) device." >&2
    exit 1
fi
if [ -z "$SUDO_PREFIX" ] && { [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; }; then
    echo "[terminal] ERROR: no read/write access to $PORT." >&2
    echo "[terminal]        Add yourself to the 'dialout' group (one-time):" >&2
    echo "[terminal]          sudo usermod -aG dialout $(id -un)   # then log out/in" >&2
    echo "[terminal]        or run elevated:  make terminal TERMINAL_SUDO=sudo" >&2
    exit 1
fi

# 4. Launch minicom. -o skips modem init (direct serial line).
echo "[terminal] minicom -> $PORT @ ${BAUD} 8N1     (exit: Ctrl-A then X;  menu: Ctrl-A Z)"
cmd=( minicom -D "$PORT" -b "$BAUD" -o )
# EXTRA_ARGS is a deliberate word-split escape hatch for extra minicom flags.
# shellcheck disable=SC2206
if [ -n "$EXTRA_ARGS" ]; then cmd+=( $EXTRA_ARGS ); fi
echo "[terminal] Running: ${SUDO_PREFIX:+$SUDO_PREFIX }${cmd[*]}"
# SUDO_PREFIX intentionally unquoted so "sudo" word-splits; empty -> runs direct.
exec ${SUDO_PREFIX} "${cmd[@]}"

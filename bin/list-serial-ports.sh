#!/usr/bin/env bash
#
# list-serial-ports.sh — list device files for *present* serial communication ports.
#
# WHAT "PRESENT" MEANS HERE
#   This lists serial ports that are backed by real hardware, not the static
#   placeholder nodes the kernel creates regardless of what is installed.
#   It does NOT mean "currently open / carrying traffic" — for that, use lsof
#   or fuser on the resulting device files (see NOTES at the bottom).
#
# WHY THE NAIVE APPROACHES FAIL
#   - `ls /dev/ttyS*` lists every statically-created node (often ttyS0..ttyS31).
#     Their existence says nothing about whether a UART chip is behind them.
#   - Checking /sys/class/tty/*/device/driver does not discriminate on modern
#     kernels (6.x): every ttyS* binds to the "serial-base/port" layer whether
#     or not real hardware is present.
#   - `setserial -g` is the classic discriminator but is frequently not installed.
#   - /proc/tty/driver/serial has the same info but is root-readable only (0400).
#
# HOW THIS SCRIPT DECIDES
#   For each /dev/ttyS* node it reads the unprivileged sysfs attribute
#       /sys/class/tty/ttySN/type
#   which is the UART port type:
#       0      = PORT_UNKNOWN  -> no chip present (skip)
#       nonzero = a detected UART (e.g. 4 = PORT_16550A) -> real port (list)
#   USB-serial (ttyUSB*) and CDC-ACM (ttyACM*) nodes are created on demand by
#   their drivers, so their mere presence already means the hardware is plugged
#   in — they are listed unconditionally.
#
# USAGE
#   ./list-serial-ports.sh            # bare: one device path per line (machine-readable)
#   ./list-serial-ports.sh --long     # rich: + by-id name, USB chip/channel, JTAG tag
#
# OUTPUT (bare)
#   One device path per line, e.g.:
#       /dev/ttyS0
#       /dev/ttyS4
#       /dev/ttyUSB0
#   Prints nothing (and exits 0) if no serial ports are present.
#
# OUTPUT (--long)
#   Per port: the device, its stable /dev/serial/by-id name (USB only), the USB
#   chip + FTDI channel + vid:pid(serial), and - for an FT4232H channel A - a
#   "likely JTAG" tag (that channel is what `make openocd` drives, not the console).
#
# PORTABILITY
#   Linux only (sysfs under /sys/class/tty). --long uses udevadm when present and
#   degrades gracefully without it. No root required.

set -o nounset
set -o pipefail

list_serial_ports() {
    # On-board UARTs: keep only those whose sysfs "type" is nonzero.
    local port
    for port in /sys/class/tty/ttyS*; do
        # Guard against the literal glob when no ttyS* exists.
        [ -e "$port/type" ] || continue
        if [ "$(cat "$port/type" 2>/dev/null)" != "0" ]; then
            printf '/dev/%s\n' "$(basename "$port")"
        fi
    done

    # USB-serial and CDC-ACM nodes exist only when their hardware is attached.
    # shopt -s nullglob makes a non-matching glob expand to nothing (rather than
    # to the literal pattern), so we can iterate cleanly with no spurious output
    # and no reliance on ls's exit status.
    shopt -s nullglob
    local dev
    for dev in /dev/ttyUSB* /dev/ttyACM*; do
        printf '%s\n' "$dev"
    done
}

# describe_port DEV -- print a rich, human line (or two) for a serial device:
# its USB chip + FTDI channel + vid:pid(serial), a stable /dev/serial/by-id name,
# and a "likely JTAG" tag for an FT4232H channel A (the MPSSE channel ADI's
# ice1000.cfg drives -- never the console). udevadm-based; degrades gracefully.
describe_port() {
    local dev="$1"
    local props vid pid ser ifnum model chip chan tag byid real l line
    # Only USB serial (ttyUSB*/ttyACM*) carries chip/channel/by-id info; print a
    # platform UART (ttyS*) as a bare path - it is never the board's USB console.
    case "$dev" in
        */ttyUSB*|*/ttyACM*) ;;
        *) printf '%s\n' "$dev"; return 0 ;;
    esac
    props=""
    if command -v udevadm >/dev/null 2>&1; then
        props="$(udevadm info -q property -n "$dev" 2>/dev/null || true)"
    fi
    getprop() { printf '%s\n' "$props" | sed -n "s/^$1=//p" | head -1; }
    vid="$(getprop ID_VENDOR_ID)"
    pid="$(getprop ID_MODEL_ID)"
    ser="$(getprop ID_SERIAL_SHORT)"
    ifnum="$(getprop ID_USB_INTERFACE_NUM)"
    model="$(getprop ID_MODEL)"

    chip=""; chan=""; tag=""
    case "$vid:$pid" in
        0403:6011) chip="FT4232H" ;;
        0403:6010) chip="FT2232H" ;;
        0403:6014) chip="FT232H" ;;
        0403:6001) chip="FT232R" ;;
        0403:6015) chip="FT-X" ;;
        10c4:ea60) chip="CP2102N" ;;
        10c4:ea70) chip="CP2105" ;;
        :)         chip="" ;;            # non-USB (ttyS*) or no udev info
        *)         chip="${model:-USB-serial}" ;;
    esac
    # FTDI dual/quad chips: map interface -> channel; MPSSE (JTAG) lives on ch.A.
    if [ -n "$ifnum" ] && { [ "$chip" = FT4232H ] || [ "$chip" = FT2232H ]; }; then
        case "$ifnum" in
            00) chan="ch.A"; tag="   <- likely JTAG (make openocd) - NOT the console" ;;
            01) chan="ch.B" ;;
            02) chan="ch.C" ;;
            03) chan="ch.D" ;;
            *)  chan="if$ifnum" ;;
        esac
    fi
    # Stable by-id symlink (USB only).
    byid=""
    if [ -d /dev/serial/by-id ]; then
        real="$(readlink -f "$dev")"
        for l in /dev/serial/by-id/*; do
            [ -e "$l" ] || continue
            if [ "$(readlink -f "$l")" = "$real" ]; then byid="$l"; break; fi
        done
    fi

    line="$dev"
    [ -n "$chip" ]    && line="$line  $chip"
    [ -n "$chan" ]    && line="$line $chan"
    [ -n "$ifnum" ]   && line="$line  if$ifnum"
    [ -n "$vid$pid" ] && line="$line  $vid:$pid"
    [ -n "$ser" ]     && line="$line ($ser)"
    printf '%s%s\n' "$line" "$tag"
    [ -n "$byid" ] && printf '      by-id: %s\n' "$byid"
}

# ---- mode dispatch --------------------------------------------------------
case "${1:-}" in
    -l|--long)  list_serial_ports | while IFS= read -r p; do describe_port "$p"; done ;;
    -h|--help)  echo "Usage: list-serial-ports.sh [--long]" ;;
    "")         list_serial_ports ;;
    *)          echo "list-serial-ports.sh: unknown arg: $1" >&2; exit 1 ;;
esac

# NOTES
#   - To find ports that are open RIGHT NOW (not merely present), pipe the
#     output to lsof, e.g.:
#         lsof $(./list-serial-ports.sh) 2>/dev/null
#     or check a single device with:  fuser -v /dev/ttyS0
#   - As root, the equivalent one-liner is:
#         grep -vE 'uart:unknown' /proc/tty/driver/serial
#         ls -1d /dev/ttyUSB* /dev/ttyACM* 2>/dev/null

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
#   ./list-serial-ports.sh
#
# OUTPUT
#   One device path per line, e.g.:
#       /dev/ttyS0
#       /dev/ttyS4
#       /dev/ttyUSB0
#   Prints nothing (and exits 0) if no serial ports are present.
#
# PORTABILITY
#   Linux only (relies on sysfs layout under /sys/class/tty). No root required.

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

list_serial_ports

# NOTES
#   - To find ports that are open RIGHT NOW (not merely present), pipe the
#     output to lsof, e.g.:
#         lsof $(./list-serial-ports.sh) 2>/dev/null
#     or check a single device with:  fuser -v /dev/ttyS0
#   - As root, the equivalent one-liner is:
#         grep -vE 'uart:unknown' /proc/tty/driver/serial
#         ls -1d /dev/ttyUSB* /dev/ttyACM* 2>/dev/null

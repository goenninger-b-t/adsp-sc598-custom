#!/usr/bin/env bash
#
# detect-console-port.sh - find which serial port is the ADSP-SC598 SOM console.
#
# The SOM-EZKIT setup usually exposes MORE THAN ONE USB-serial port (the console
# UART bridge, plus other adapters / a JTAG pod), and which /dev/ttyUSBx the
# console lands on is not fixed - it depends on enumeration order and what else
# is plugged in. Worse, the console bridge chip is not constant across ADI
# carriers (this board uses a CP2102N; others ship FT232 / FT4232H), so you
# cannot identify it by USB chip alone.
#
# So this ACTIVELY PROBES: for each candidate it configures the line, nudges it
# with a couple of carriage returns, and listens briefly for output only the SOM
# console produces - U-Boot, "Hit any key", a Linux `login:` / kernel banner, the
# adsp-sc598 hostname, or ADI strings. The port that answers like the console is
# reported. This is board-agnostic and definitive.
#
# REQUIREMENT: the board must be POWERED and past the boot ROM (sitting in U-Boot
# or Linux). In JTAG/no-boot mode the console is silent until `make boot` drives
# it, so nothing will answer - power-cycle to a normal boot first.
#
# Known non-console ports are skipped up front: the ADI ICE (JTAG pod, USB vendor
# 064b) and an FT4232H/FT2232H channel A (the MPSSE/JTAG channel `make openocd`
# uses). Ports already open (e.g. a live `make terminal`) are skipped and noted.
#
# OUTPUT: the detected console device path on stdout (machine-readable), e.g.
#     /dev/ttyUSB0
# so it can feed other targets:
#     make terminal SERIAL_PORT="$(make -s detect-console-port)"
# Human progress + the final summary go to stderr. --long adds per-port detail.
#
# EXIT: 0 = detected (path on stdout); 1 = nothing answered; 2 = no ports present.
#
# PORTABILITY: Linux. Needs read/write on the ports (dialout group or sudo) and
# `udevadm` for the JTAG-skip (degrades gracefully without it).

set -o nounset
set -o pipefail

BAUD="115200"
LIST_SCRIPT=""
TIMEOUT="3"
LONG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baud)        BAUD="$2";        shift 2 ;;
        --list-script) LIST_SCRIPT="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2";     shift 2 ;;
        --long)        LONG=1;           shift ;;
        *) echo "detect-console-port.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

say()  { printf '[detect] %s\n' "$*" >&2; }
note() { [ "$LONG" = 1 ] && printf '[detect]   %s\n' "$*" >&2 || true; }

# Output only the SOM console emits (matched case-insensitively, text-safe).
SIG='U-Boot|Hit any key to stop|Starting kernel|Booting Linux|Linux version|login:|adsp-sc598|sc598-som|ADSP-SC|Analog Devices Yocto|=> '

# Classify a port as a JTAG channel we must NOT probe as a console.
is_jtag_port() {
    local dev="$1" props vid pid ifn
    command -v udevadm >/dev/null 2>&1 || return 1
    props="$(udevadm info -q property -n "$dev" 2>/dev/null || true)"
    vid="$(printf '%s\n' "$props" | sed -n 's/^ID_VENDOR_ID=//p'        | head -1)"
    pid="$(printf '%s\n' "$props" | sed -n 's/^ID_MODEL_ID=//p'         | head -1)"
    ifn="$(printf '%s\n' "$props" | sed -n 's/^ID_USB_INTERFACE_NUM=//p'| head -1)"
    [ "$vid" = "064b" ] && return 0                                  # ADI ICE (JTAG pod)
    case "$vid:$pid" in 0403:6011|0403:6010) [ "$ifn" = "00" ] && return 0 ;; esac  # FT4232H/FT2232H ch.A = JTAG
    return 1
}

# Nudge a port and capture whatever it says for $TIMEOUT seconds.
probe_port() {
    local dev="$1"
    stty -F "$dev" "$BAUD" cs8 -cstopb -parenb -echo raw 2>/dev/null || return 1
    {
        timeout "$TIMEOUT" cat "$dev" 2>/dev/null &
        local cp=$!
        sleep 0.5; printf '\r' > "$dev" 2>/dev/null
        sleep 0.7; printf '\r' > "$dev" 2>/dev/null
        wait "$cp"
    } 2>/dev/null
}

# ---- enumerate USB-serial candidates ----
mapfile -t allports < <( { if [ -n "$LIST_SCRIPT" ] && [ -x "$LIST_SCRIPT" ]; then bash "$LIST_SCRIPT"; else ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null; fi; } 2>/dev/null )
cands=()
for p in ${allports[@]+"${allports[@]}"}; do
    case "$p" in */ttyUSB*|*/ttyACM*) [ -c "$p" ] && cands+=("$p") ;; esac
done
if [ "${#cands[@]}" -eq 0 ]; then
    say "no USB-serial ports present - connect the SOM console cable (see: make list-serial-ports)."
    exit 2
fi

# ---- probe ----
say "probing ${#cands[@]} serial port(s) for the SC598 console (${TIMEOUT}s each); board must be booted ..."
uart_cands=()
busy_seen=0
found=""
for p in "${cands[@]}"; do
    if is_jtag_port "$p"; then note "$p: JTAG channel - skip"; continue; fi
    uart_cands+=("$p")
    if fuser "$p" >/dev/null 2>&1; then note "$p: busy (in use - close minicom?) - skip"; busy_seen=1; continue; fi
    if [ ! -r "$p" ] || [ ! -w "$p" ]; then note "$p: no access (dialout group or TERMINAL_SUDO) - skip"; continue; fi
    note "$p: probing ..."
    out="$(probe_port "$p" 2>/dev/null || true)"
    if printf '%s' "$out" | grep -aqiE "$SIG"; then
        note "$p: answered like the SOM console"
        found="$p"
        break
    fi
    note "$p: no console response"
done

if [ -n "$found" ]; then
    printf '%s\n' "$found"
    say "console detected: $found"
    exit 0
fi

# Nothing answered. If there is exactly ONE plausible UART, offer it as a guess.
if [ "${#uart_cands[@]}" -eq 1 ]; then
    printf '%s\n' "${uart_cands[0]}"
    say "no console output seen, but ${uart_cands[0]} is the only non-JTAG UART - likely the console (unconfirmed; is the board booted?)."
    exit 0
fi

say "could not detect the SOM console on any port."
say "  probed UART candidates: ${uart_cands[*]:-none}"
[ "$busy_seen" = 1 ] && say "  (one or more ports were busy - a port already open in minicom is often the console itself.)"
say "  Make sure the board is powered and past the boot ROM (U-Boot/Linux); in JTAG/no-boot"
say "  the console is silent until 'make boot'. Or pick it from: make list-serial-ports"
exit 1

#!/usr/bin/env bash
#
# reset-board.sh - reset the attached ADSP-SC598 over the ICE/JTAG link.
#
# Runs a one-shot OpenOCD batch (init -> reset -> shutdown), like `make
# board-info`, using the same ADI interface/target cfgs, then exits. It needs the
# adapter to itself - do NOT run it while `make openocd` is holding it (you'd get
# a libusb "device busy" error).
#
# WHAT "reset" MEANS HERE: the SC598 target cfg declares `reset_config trst_only`
# (the ICE has no system-reset / SRST line), so OpenOCD's `reset` runs the cfg's
# reset-assert handler = ADI's on-chip RCU + CTI warm system reset.
#
# IMPORTANT LIMITATION (verified on hardware): a core that is ACTIVELY RUNNING AN
# OS - e.g. Linux from a previous `make boot` - CANNOT be reset this way. OpenOCD
# can halt it, but ADI's RCU/CTI sequence then ABORTS ("abort occurred" / "Error
# executing event reset-assert"); the core is NOT reset and resumes the OS. With
# no SRST line to force it, the only reset in that state is a POWER-CYCLE (BMODE
# in JTAG/no-boot). This script reports that case as "COULD NOT RESET" - it does
# not claim success. The reset DOES complete on a core that is not deep in an OS
# (the boot ROM, U-Boot/SPL, or bare metal), where the sequence ends with
# "system reset done".
#
# MODE (--mode, config.mk RESET_MODE), applied when the reset actually completes:
#   halt  reset, leave the A55 halted at the reset vector.  [default]
#   run   reset, then run from the BMODE boot source.
#   init  like halt, plus any OpenOCD reset-init events.
#
# Success is judged from OpenOCD's OUTPUT, not its exit code (a failed
# reset-assert is only logged, after which OpenOCD still reaches `shutdown` and
# exits 0): "system reset done" with no abort = reset completed; an abort = could
# not reset (power-cycle); never reaching the reset = the ICE could not be claimed.
#
# OpenOCD + its .cfg scripts come from the ADI SDK (`make sdk`); all paths/options
# are the OPENOCD_* vars in config.mk, passed in by the Makefile.
#
# PORTABILITY: Linux; needs the ADI OpenOCD + an ICE-1000/2000. Raw USB access to
# the ICE usually needs sudo (OPENOCD_SUDO) or a udev rule (see README).

set -euo pipefail

OPENOCD_BIN=""
SCRIPTS=""
ICE="ice1000"
TARGET="adspsc59x_a55.cfg"
SUDO_PREFIX=""
MACHINE=""
MODE="halt"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --openocd-bin) OPENOCD_BIN="$2"; shift 2 ;;
        --scripts-dir) SCRIPTS="$2";     shift 2 ;;
        --ice)         ICE="$2";         shift 2 ;;
        --target)      TARGET="$2";      shift 2 ;;
        --sudo)        SUDO_PREFIX="$2"; shift 2 ;;
        --machine)     MACHINE="$2";     shift 2 ;;
        --mode)        MODE="$2";        shift 2 ;;
        *) echo "reset-board.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    halt|run|init) ;;
    *) echo "reset-board.sh: invalid --mode '$MODE' (use halt|run|init)" >&2; exit 1 ;;
esac

# --- validate OpenOCD + the cfg scripts (point at `make sdk` when missing) ---
if [ -z "$OPENOCD_BIN" ] || [ ! -x "$OPENOCD_BIN" ]; then
    echo "[reset-board] ERROR: OpenOCD not found/executable: '${OPENOCD_BIN:-<unset>}'" >&2
    echo "[reset-board]        Build + install the ADI SDK first:  make sdk" >&2
    exit 1
fi
IFACE_CFG="$SCRIPTS/interface/$ICE.cfg"
TARGET_CFG="$SCRIPTS/target/$TARGET"
for f in "$IFACE_CFG" "$TARGET_CFG"; do
    if [ ! -f "$f" ]; then
        echo "[reset-board] ERROR: OpenOCD config not found: $f" >&2
        echo "[reset-board]        Check OPENOCD_SCRIPTS / OPENOCD_ICE / OPENOCD_TARGET in config.mk." >&2
        exit 1
    fi
done

# --- the OpenOCD/Tcl that performs + reports the reset. Single-quoted heredoc:
#     NOTHING here is expanded by bash - the [brackets] are Tcl. The catch keeps
#     the post-reset echo + shutdown running even when `reset` raises on the
#     reset-assert abort; bash decides the verdict from the output. -----------
read -r -d '' RB_TCL <<'TCL' || true
proc rb_cpu {} {
    foreach n [target names] { if {[string match *.cpu $n]} { return $n } }
    return ""
}
proc rb_state {} {
    set t [rb_cpu]
    if {$t eq ""} { return "unknown" }
    set s "unknown"
    catch {set s [$t curstate]}
    return $s
}
# reset_config is trst_only (no SRST), so `reset` runs the target cfg's
# reset-assert handler = on-chip RCU+CTI warm reset. On a core that is running an
# OS the sequence aborts (caught here) and the core is NOT reset; bash detects
# that from the output and reports COULD NOT RESET.
proc reset_board {mode} {
    echo "  pre-reset  core state : [rb_state]"
    switch -- $mode {
        run     { catch {reset run} }
        init    { catch {reset init} }
        default { catch {reset halt} }
    }
    echo "  post-reset core state : [rb_state]"
}
TCL

echo "[reset-board] Resetting ${MACHINE:-the board} over JTAG ($ICE) via OpenOCD batch (mode=$MODE) ..."
echo "[reset-board]   $OPENOCD_BIN"
echo "[reset-board]   -f $IFACE_CFG"
echo "[reset-board]   -f $TARGET_CFG"
echo "[reset-board]   NOTE: needs the adapter to itself - stop 'make openocd' first if it is running."
echo

CMD=( "$OPENOCD_BIN"
      -f "$IFACE_CFG"
      -f "$TARGET_CFG"
      -c "gdb_port disabled"
      -c "tcl_port disabled"
      -c "telnet_port disabled"
      -c "$RB_TCL"
      -c "init"
      -c "reset_board $MODE"
      -c "shutdown" )

# Run OpenOCD live (tee) AND capture the output to judge success. OpenOCD's exit
# code is useless here (a failed reset-assert is logged but it still reaches
# `shutdown` and exits 0), so scan the output: ADI's warm reset ends with
# "system reset done" only when it actually completes; on a running-OS core it
# aborts before that.
RB_OUT="$(mktemp "${TMPDIR:-/tmp}/reset-board.XXXXXX")"
trap 'rm -f "$RB_OUT"' EXIT

# SUDO_PREFIX intentionally unquoted so "sudo" word-splits; empty -> runs direct.
# pipefail off so the pipeline's status is tee's (0) and `set -e` doesn't abort
# before we render the verdict.
set +o pipefail
${SUDO_PREFIX} "${CMD[@]}" 2>&1 | tee "$RB_OUT"
set -o pipefail

echo
if grep -q 'system reset done' "$RB_OUT" \
   && ! grep -qE 'abort occurred|Error executing event reset' "$RB_OUT"; then
    echo "[reset-board] RESET OK (mode=$MODE) - SoC reset over JTAG."
    exit 0
fi

if grep -q 'post-reset core state' "$RB_OUT"; then
    # OpenOCD connected and ran the reset, but ADI's RCU/CTI sequence aborted.
    echo "[reset-board] COULD NOT RESET - the reset was attempted but ADI's RCU/CTI"
    echo "[reset-board]   sequence aborted. This is the running-OS case: a core already"
    echo "[reset-board]   running Linux (e.g. from a previous 'make boot') gets halted but"
    echo "[reset-board]   NOT reset, then resumes. The ICE has no SRST line to force it."
    echo "[reset-board]   Fix: POWER-CYCLE the board (BMODE in JTAG/no-boot)."
    exit 1
fi

echo "[reset-board] RESET FAILED - OpenOCD could not talk to the board, so no reset was issued."
echo "[reset-board]   Check the ICE is connected and FREE - not held by 'make openocd' or a"
echo "[reset-board]   running 'make boot' (libusb 'claim interface failed -6' = adapter busy)"
echo "[reset-board]   - and that the BMODE/JTAG wiring is in place."
exit 1

#!/usr/bin/env bash
#
# gdb-run.sh — attach the ADI SDK's aarch64 GDB to a running OpenOCD (make openocd).
#
# Reproduces the "Terminal3: GDB" step of the ADI getting-started guide: while
# `make openocd` holds one terminal serving a GDB remote on port 3333, this runs
# the SDK cross-GDB in another terminal and connects to it:
#
#     aarch64-...-gdb [u-boot-spl-<board>.elf] -ex "target extended-remote :3333"
#
# then drops to the interactive (gdb) prompt so you can `load` U-Boot into RAM
# and `c`. GDB is only a TCP client to OpenOCD — no sudo, no USB access needed.
#
# PORTABILITY: Linux. Needs the ADI SDK installed (make sdk) and OpenOCD already
# running (make openocd, in another terminal).

set -euo pipefail

GDB_BIN=""
HOST=""
PORT="3333"
ELF=""
DEPLOY_DIR=""
MACHINE=""
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gdb-bin)    GDB_BIN="$2";    shift 2 ;;
        --host)       HOST="$2";       shift 2 ;;
        --port)       PORT="$2";       shift 2 ;;
        --elf)        ELF="$2";        shift 2 ;;
        --deploy-dir) DEPLOY_DIR="$2"; shift 2 ;;
        --machine)    MACHINE="$2";    shift 2 ;;
        --extra)      EXTRA_ARGS="$2"; shift 2 ;;
        *) echo "gdb-run.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# 1. Locate the SDK GDB (GDB_BIN is auto-resolved by config.mk's $(wildcard);
#    empty/missing means the SDK isn't installed where we looked).
if [ -z "$GDB_BIN" ] || [ ! -x "$GDB_BIN" ]; then
    echo "[gdb] ERROR: SDK aarch64 GDB not found${GDB_BIN:+: $GDB_BIN}" >&2
    echo "[gdb]        Build + install the SDK first:  make sdk" >&2
    echo "[gdb]        or set GDB_BIN to your aarch64-...-gdb." >&2
    exit 1
fi

# 2. Pick the ELF: explicit GDB_ELF wins, else best-effort from the deploy dir.
#    MACHINE adsp-sc598-som-ezkit -> BOARD sc598-som-ezkit (the U-Boot elf names).
BOARD="${MACHINE#adsp-}"
if [ -z "$ELF" ] && [ -n "$DEPLOY_DIR" ] && [ -n "$BOARD" ]; then
    for cand in "$DEPLOY_DIR/u-boot-spl-$BOARD.elf" \
                "$DEPLOY_DIR/u-boot-proper-$BOARD.elf" \
                "$DEPLOY_DIR/u-boot-$BOARD.elf"; do
        if [ -f "$cand" ]; then ELF="$cand"; echo "[gdb] auto-loaded ELF: $cand"; break; fi
    done
fi
if [ -n "$ELF" ] && [ ! -f "$ELF" ]; then
    echo "[gdb] ERROR: ELF not found: $ELF" >&2
    exit 1
fi

# 3. Connection target. Empty HOST -> localhost (the ":PORT" form the guide uses).
if [ -n "$HOST" ]; then TARGET="$HOST:$PORT"; else TARGET=":$PORT"; fi

# 4. Pre-flight: is OpenOCD actually listening? (Only checkable for localhost.)
if [ -z "$HOST" ] && command -v ss >/dev/null 2>&1; then
    if ! ss -ltn 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {f=1} END {exit !f}'; then
        echo "[gdb] ERROR: nothing is listening on $TARGET — OpenOCD isn't running." >&2
        echo "[gdb]        Start it in another terminal first:  make openocd" >&2
        exit 1
    fi
fi

echo "[gdb] Attaching to OpenOCD at $TARGET${ELF:+  (symbols: $(basename "$ELF"))}"
echo "[gdb] At the prompt:  (gdb) load   then   (gdb) c     (quit to exit)"
echo ""

# 5. Build + exec interactive GDB. -ex runs the connect, then leaves you at the
#    (gdb) prompt. ELF (if any) is the program / symbol file.
cmd=( "$GDB_BIN" )
if [ -n "$ELF" ]; then cmd+=( "$ELF" ); fi
cmd+=( -ex "target extended-remote $TARGET" )
# EXTRA_ARGS is a deliberate word-split escape hatch for extra gdb args / -ex.
# shellcheck disable=SC2206
if [ -n "$EXTRA_ARGS" ]; then cmd+=( $EXTRA_ARGS ); fi

echo "[gdb] Running: ${cmd[*]}"
exec "${cmd[@]}"

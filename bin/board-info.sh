#!/usr/bin/env bash
#
# board-info.sh - probe the connected ADSP-SC598 over JTAG and print as much as
# it can about the silicon: scan-chain TAP IDCODEs, the CoreSight DAP / ROM
# table, the OpenOCD targets + state, the Cortex-A55 core registers, and a set
# of SC598 memory-mapped ID/status registers (silicon revision, boot mode, DDR
# controller).
#
# HOW: it drives OpenOCD itself in a one-shot batch (init -> queries -> shutdown)
# using the same ADI interface/target cfgs as `make openocd`. It momentarily
# HALTS the Cortex-A55 to read registers, then RESUMES it.
#
# IMPORTANT: this needs exclusive access to the JTAG adapter, so do NOT run it
# while `make openocd` is holding the adapter (you'll get a libusb "device busy"
# / cannot-connect error). Run it standalone instead.
#
# OpenOCD + its .cfg scripts come from the ADI SDK (`make sdk`). All paths/options
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --openocd-bin) OPENOCD_BIN="$2"; shift 2 ;;
        --scripts-dir) SCRIPTS="$2";     shift 2 ;;
        --ice)         ICE="$2";         shift 2 ;;
        --target)      TARGET="$2";      shift 2 ;;
        --sudo)        SUDO_PREFIX="$2"; shift 2 ;;
        --machine)     MACHINE="$2";     shift 2 ;;
        *) echo "board-info.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --- validate OpenOCD + the cfg scripts (point at `make sdk` when missing) ---
if [ -z "$OPENOCD_BIN" ] || [ ! -x "$OPENOCD_BIN" ]; then
    echo "[board-info] ERROR: OpenOCD not found/executable: '${OPENOCD_BIN:-<unset>}'" >&2
    echo "[board-info]        Build + install the ADI SDK first:  make sdk" >&2
    exit 1
fi
IFACE_CFG="$SCRIPTS/interface/$ICE.cfg"
TARGET_CFG="$SCRIPTS/target/$TARGET"
for f in "$IFACE_CFG" "$TARGET_CFG"; do
    if [ ! -f "$f" ]; then
        echo "[board-info] ERROR: OpenOCD config not found: $f" >&2
        echo "[board-info]        Check OPENOCD_SCRIPTS / OPENOCD_ICE / OPENOCD_TARGET in config.mk." >&2
        exit 1
    fi
done

# --- the OpenOCD/Tcl that does the probing (catch-wrapped so one failed query
#     never aborts the rest). Single-quoted heredoc: NOTHING here is expanded by
#     bash - the $vars and [brackets] are Tcl. -------------------------------
read -r -d '' BI_TCL <<'TCL' || true
# clear a DP sticky error (best effort) so probing an ABSENT address does not
# poison subsequent transactions - including the final core resume.
proc bi_dap_clear {} {
    set d ""
    catch {set d [lindex [dap names] 0]}
    if {$d ne ""} { catch {$d dpreg 0 0x1e} }   ;# ABORT: clear STK*/WDERR/ORUNERR
}
# read one 32-bit MMR via read_memory (over the AXI mem-ap). The read is wrapped
# in `capture` so a bus fault on an ABSENT peripheral is swallowed instead of
# spewing "JTAG-DP STICKY ERROR" to the console; on failure we clear the sticky
# error and return -1. (A global passes the value out of the capture script.)
proc bi_word {t addr} {
    if {$t ne ""} { catch {targets $t} }
    catch {unset ::_bi_r}
    catch { capture { set ::_bi_r [read_memory $addr 32 1] } }
    if {![info exists ::_bi_r]} { bi_dap_clear; return -1 }
    set v [lindex $::_bi_r 0]
    unset ::_bi_r
    return $v
}
proc bi_show {t label addr} {
    set v [bi_word $t $addr]
    if {$v < 0} { echo [format "  %-20s %-12s : <unreadable>" $label $addr] ; return -1 }
    echo [format "  %-20s %-12s : 0x%08x" $label $addr $v]
    return $v
}
# run a query and echo its CAPTURED console output. scan_chain / targets /
# dap info / reg print via command_print, which is returned (not printed) when
# the command runs inside a proc - so capture it and echo, else it shows nothing.
proc bi_cap {cmd} {
    if {[catch {set out [capture $cmd]} e]} { echo "  ($cmd: $e)"; return }
    echo $out
}
# decode one DMC (DDR controller) CFG register value -> SDRAM bytes for that
# controller. CFG fields: IFWID[3:0], SDRWID[7:4], SDRSIZE[11:8], EXTBANK[15:12].
# total = per-device-density x (interface/device width ratio) x ranks.
# returns 0 if the controller is not configured (CFG==0), -1 if undecodable.
proc bi_dmc_bytes {cfg} {
    if {$cfg <= 0} { return 0 }
    set ifwid   [expr {$cfg & 0xf}]
    set sdrwid  [expr {($cfg >> 4) & 0xf}]
    set sdrsize [expr {($cfg >> 8) & 0xf}]
    set extbank [expr {($cfg >> 12) & 0xf}]
    set dens {64 128 256 512 1024 2048 4096 8192}   ;# Mbit/device by SDRSIZE
    if {$sdrsize >= [llength $dens] || $sdrwid == 0} { return -1 }
    set ndev [expr {$ifwid / $sdrwid}]
    if {$ndev < 1} { set ndev 1 }
    return [expr {[lindex $dens $sdrsize] * $ndev * ($extbank + 1) / 8 * 1048576}]
}
proc bi_ram {axi} {
    # SC59x DDR maps at 0x80000000. Detect every DDR controller the family
    # defines (DMC0 @ 0x31070040, DMC1 @ 0x31073040) by reading each CFG live;
    # absent controllers bus-fault and are skipped quietly (see bi_word). Each
    # populated controller is one bank, laid out contiguously from the base, and
    # the sizes are summed. To support a future part with more DMCs, extend the
    # candidate list below (only probe addresses known to be DMC CFG registers -
    # reading an unrelated peripheral would misdecode as a bank).
    set base 0x80000000
    set dmcs { {DMC0 0x31070040} {DMC1 0x31073040} }
    set dens {64 128 256 512 1024 2048 4096 8192}
    echo [format "  DDR base            : 0x%08x" $base]
    set total 0
    set addr  $base
    set banks 0
    foreach d $dmcs {
        set name    [lindex $d 0]
        set cfgaddr [lindex $d 1]
        set cfg [bi_word $axi $cfgaddr]
        if {$cfg <= 0} {
            echo [format "  %-5s (CFG %s) : absent / not configured" $name $cfgaddr]
            continue
        }
        set b [bi_dmc_bytes $cfg]
        if {$b <= 0} {
            echo [format "  %-5s (CFG %s) : CFG=0x%08x  (undecodable)" $name $cfgaddr $cfg]
            continue
        }
        echo [format "  %-5s @ 0x%08x : %4d MB  (CFG=0x%08x, %d Mbit/device)" \
              $name $addr [expr {$b/1048576}] $cfg [lindex $dens [expr {($cfg >> 8) & 0xf}]]]
        set total [expr {$total + $b}]
        set addr  [expr {$addr + $b}]
        incr banks
    }
    if {$banks > 0} {
        echo [format "  total DRAM          : %d MB  (0x%08x) across %d bank(s)" \
              [expr {$total/1048576}] $total $banks]
        echo [format "  DDR address range   : 0x%08x - 0x%08x" $base [expr {$base + $total}]]
    } else {
        echo "  total DRAM          : <no DDR controller readable>"
    }
}
proc board_info_dump {} {
    set cpu ""; set axi ""
    foreach t [target names] {
        if {[string match *.cpu $t]} { set cpu $t }
        if {[string match *.axi $t]} { set axi $t }
    }

    echo "===== JTAG scan chain (TAP IDCODEs) ====="
    echo "  expected: ADI JTAG controller 0x0282e0cb, CoreSight DAP 0x4ba06477"
    bi_cap {scan_chain}

    echo ""
    echo "===== OpenOCD targets ====="
    bi_cap {targets}

    echo ""
    echo "===== CoreSight DAP / ROM table (cores + debug components) ====="
    if {$cpu ne ""} { catch {targets $cpu} }
    bi_cap {dap info}

    echo ""
    echo "===== Cortex-A55 registers (core halted momentarily) ====="
    if {$cpu ne ""} { catch {targets $cpu} }
    if {[catch {halt} e]} { echo "  halt failed: $e" }
    bi_cap {reg}

    echo ""
    echo "===== SC598 ID / status registers (memory-mapped) ====="
    set rev [bi_show $axi "CDU0_REVID" 0x3108F048]
    if {$rev >= 0} {
        echo [format "    -> silicon stepping ~= %d.%d (CDU0 REVID major.minor)" [expr {($rev >> 4) & 0xf}] [expr {$rev & 0xf}]]
    }
    set rcu [bi_show $axi "RCU0_STAT" 0x3108C004]
    if {$rcu >= 0} {
        set bm [expr {($rcu >> 8) & 0xf}]
        set names {JTAG/BOOTROM {QSPI Master} {QSPI Slave} UART {LP0 Slave} OSPI eMMC}
        set bn "unknown"
        if {$bm < [llength $names]} { set bn [lindex $names $bm] }
        echo [format "    -> BMODE (boot source, bits 11:8) = %d  (%s)" $bm $bn]
    }
    bi_show $axi "DMC0_CTL (DDR)"  0x31070004
    bi_show $axi "DMC0_STAT(DDR)"  0x31070008
    bi_show $axi "DMC0_CFG (DDR)"  0x31070040
    bi_show $axi "TAPC_DBG_CTL"    0x31131000

    echo ""
    echo "===== RAM (DDR) ====="
    bi_ram $axi

    echo ""
    if {$cpu ne ""} { catch {targets $cpu}; catch {resume}; echo "===== core resumed =====" }
}
TCL

echo "[board-info] Probing ${MACHINE:-the board} over JTAG ($ICE) via OpenOCD batch ..."
echo "[board-info]   $OPENOCD_BIN"
echo "[board-info]   -f $IFACE_CFG"
echo "[board-info]   -f $TARGET_CFG"
echo "[board-info]   NOTE: needs the adapter to itself - stop 'make openocd' first if it is running."
echo

CMD=( "$OPENOCD_BIN"
      -f "$IFACE_CFG"
      -f "$TARGET_CFG"
      -c "gdb_port disabled"
      -c "tcl_port disabled"
      -c "telnet_port disabled"
      -c "$BI_TCL"
      -c "init"
      -c "board_info_dump"
      -c "shutdown" )

# SUDO_PREFIX intentionally unquoted so "sudo" word-splits; empty -> runs direct.
exec ${SUDO_PREFIX} "${CMD[@]}"

#!/usr/bin/env bash
#
# tftp-server.sh — inspect or ensure the host's TFTP server for `make tftp` netboot.
#
# SUBCOMMANDS
#   status   Report whether a TFTP server is running, the address:port it is
#            listening on, the directory it serves, and its config file path.
#            Always exits 0 (it is a query) — read the output for up/down.
#   ensure   Make sure a TFTP server is running: if one is already up, do nothing;
#            otherwise start an installed server (via sudo). Exits 0 if a server
#            ends up running, non-zero if none is installed / it could not start.
#   test     List the files in the served directory (a filesystem view — TFTP has
#            no directory-listing opcode, RFC 1350) and verify retrieval by
#            actually fetching the smallest file over TFTP from loopback and
#            byte-comparing it to the source. Exits 0 on a successful fetch,
#            non-zero otherwise. Overrides: TFTP_TEST_FILE=<name>, TFTP_TEST_HOST=<ip>.
#
# WHY THIS EXISTS
#   `make tftp` only *stages* boot files into TFTP_DIR; it never checks that a
#   TFTP daemon is actually serving that directory. A board that won't net-boot
#   is almost always one of:
#     (a) no TFTP server running, or
#     (b) a server running but serving a *different* directory than you staged.
#   `status` diagnoses both; `ensure` fixes (a). Neither one reconfigures a
#   server's served directory (that edits system files other users may rely on) —
#   a (b) mismatch is reported as a WARNING for you to resolve deliberately.
#
# SERVERS RECOGNISED  (the two named in the README, plus atftpd)
#   tftpd-hpa  unit tftpd-hpa  dir <- TFTP_DIRECTORY in /etc/default/tftpd-hpa
#   atftpd     unit atftpd     dir <- last token of OPTIONS in /etc/default/atftpd
#   dnsmasq    unit dnsmasq    dir <- tftp-root= in /etc/dnsmasq.conf|/etc/dnsmasq.d/*
#              (only counts as a TFTP server when `enable-tftp` is set; only
#               auto-started by `ensure` in that case, since starting dnsmasq
#               otherwise hijacks host DNS/DHCP)
#
# DETECTION
#   - "Is TFTP served at all?"  -> a UDP listener on port 69 (ss). Daemon-agnostic,
#     so it also catches inetd / socket-activated servers we don't recognise.
#   - "Which daemon, serving where?" -> systemctl is-active on the known units +
#     parsing their config for the served dir. No root needed for `status`.
#
# PORTABILITY
#   Linux + systemd + iproute2 (`ss`), Debian/Ubuntu config layout. No root for
#   `status`; `ensure` uses sudo only to start a stopped, already-installed server.

set -euo pipefail

SUBCMD="${1:-}"
shift || true

WANT_DIR=""   # the project's TFTP_DIR (optional), for cross-checking
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tftp-dir) WANT_DIR="${2:-}"; shift 2 ;;
        *) echo "tftp-server.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Known servers, in auto-start preference order. dnsmasq is last and is only
# auto-started when its config already opts into TFTP (see above).
KNOWN_SERVERS=(tftpd-hpa atftpd dnsmasq)

have()        { command -v "$1" >/dev/null 2>&1; }
svc_active()  { [ "$(systemctl is-active "$1" 2>/dev/null || true)" = active ]; }

svc_present() {
    # Installed if the unit file exists, or (covers inetd-only setups) the daemon
    # binary is on PATH. /usr/sbin is not always on a non-root PATH, so probe both.
    if systemctl list-unit-files "$1.service" --no-legend 2>/dev/null | grep -q .; then
        return 0
    fi
    case "$1" in
        tftpd-hpa) have in.tftpd || [ -x /usr/sbin/in.tftpd ] ;;
        atftpd)    have atftpd   || [ -x /usr/sbin/atftpd ] ;;
        dnsmasq)   have dnsmasq  || [ -x /usr/sbin/dnsmasq ] ;;
        *) return 1 ;;
    esac
}

# Is anything listening on UDP/69? Ground truth, independent of the daemon.
# The header row's $4 is "Local" (never matches :69), so -H is unnecessary.
udp69_listening() {
    have ss || return 1
    ss -uln 2>/dev/null | awk '$4 ~ /:69$/ {f=1} END{exit !f}'
}

# Best-effort name of the process behind udp/69. Empty unless we can see it
# (foreign-process visibility needs privilege; harmless when blank).
udp69_proc() {
    have ss || return 0
    ss -ulnp 2>/dev/null | awk '$4 ~ /:69$/' \
        | sed -nE 's/.*users:\(\("([^"]+)".*/\1/p' | head -1
}

# Every address:port the daemon is bound to on port 69, joined as "a, b"
# (typically one IPv4 + one IPv6, e.g. "0.0.0.0:69, [::]:69"). The socket's
# local address is visible to any user; no privilege needed.
udp69_addrs() {
    have ss || return 0
    ss -uln 2>/dev/null | awk '$4 ~ /:69$/ {a = a sep $4; sep = ", "} END {if (a) print a}'
}

cfg_line() {  # cfg_line FILE SED_EXPR -> last matching capture (empty if none)
    [ -f "$1" ] || return 0
    sed -nE "$2" "$1" | tail -1
}

server_dir() {  # server_dir <svc> -> prints served dir, or nothing if undeterminable
    case "$1" in
        tftpd-hpa)
            cfg_line /etc/default/tftpd-hpa \
                's/^[[:space:]]*TFTP_DIRECTORY[[:space:]]*=[[:space:]]*"?([^"#]*)"?.*/\1/p' \
                | sed -E 's/[[:space:]]+$//'
            ;;
        atftpd)
            local opts
            opts="$(cfg_line /etc/default/atftpd \
                's/^[[:space:]]*OPTIONS[[:space:]]*=[[:space:]]*"?([^"]*)"?.*/\1/p')"
            if [ -n "$opts" ]; then awk '{print $NF}' <<<"$opts"; fi
            ;;
        dnsmasq)
            local f
            for f in /etc/dnsmasq.conf /etc/dnsmasq.d/*.conf; do
                [ -f "$f" ] || continue
                sed -nE 's/^[[:space:]]*tftp-root[[:space:]]*=[[:space:]]*([^,#[:space:]]+).*/\1/p' "$f"
            done | tail -1
            ;;
    esac
}

server_conf() {  # server_conf <svc> -> config file path(s) for that daemon
    case "$1" in
        tftpd-hpa) echo /etc/default/tftpd-hpa ;;
        atftpd)    echo /etc/default/atftpd ;;
        dnsmasq)
            # dnsmasq config can be split across /etc/dnsmasq.d/. Report the
            # file(s) that actually carry the tftp directives; fall back to the
            # main conf if none match (e.g. config readable only as root).
            local f hits=""
            for f in /etc/dnsmasq.conf /etc/dnsmasq.d/*.conf; do
                [ -f "$f" ] || continue
                if grep -qE '^[[:space:]]*(enable-tftp|tftp-root)' "$f" 2>/dev/null; then
                    hits="${hits:+$hits }$f"
                fi
            done
            echo "${hits:-/etc/dnsmasq.conf}"
            ;;
    esac
}

dnsmasq_tftp_enabled() {
    local f
    for f in /etc/dnsmasq.conf /etc/dnsmasq.d/*.conf; do
        [ -f "$f" ] || continue
        grep -qE '^[[:space:]]*enable-tftp([[:space:]]|=|$)' "$f" && return 0
    done
    return 1
}

# A known server "counts" as serving TFTP if its unit is active — except dnsmasq,
# which must also have TFTP turned on in its config.
serves_tftp() {
    svc_active "$1" || return 1
    if [ "$1" = dnsmasq ]; then dnsmasq_tftp_enabled || return 1; fi
    return 0
}

# Globals filled by detect():
RUNNING_SVC=""
SERVING_DIR=""
detect() {
    RUNNING_SVC=""
    SERVING_DIR=""
    local s
    for s in "${KNOWN_SERVERS[@]}"; do
        if serves_tftp "$s"; then
            RUNNING_SVC="$s"
            SERVING_DIR="$(server_dir "$s" || true)"
            break
        fi
    done
}

crosscheck_dir() {
    # Compare the server's served dir against the project's TFTP_DIR, if given.
    # Only meaningful when a recognised daemon is actually running (only then do
    # we know a served dir); skip entirely otherwise.
    [ -n "$WANT_DIR" ] || return 0
    [ -n "$RUNNING_SVC" ] || return 0
    if [ -z "${SERVING_DIR:-}" ]; then
        echo "[tftp]   note   : couldn't read the server's served dir to cross-check"
        echo "[tftp]            against TFTP_DIR=$WANT_DIR"
        return 0
    fi
    if [ "${SERVING_DIR%/}" = "${WANT_DIR%/}" ]; then
        echo "[tftp]   OK     : server serves your TFTP_DIR ($WANT_DIR)"
    else
        echo "[tftp]   WARNING: TFTP_DIR ($WANT_DIR) != served dir ($SERVING_DIR)"
        echo "[tftp]            'make tftp' stages into TFTP_DIR, but the server serves"
        echo "[tftp]            elsewhere — the board won't see the staged files."
        echo "[tftp]            Point one at the other (edit the server config, or set"
        echo "[tftp]            TFTP_DIR to $SERVING_DIR)."
    fi
}

print_status() {
    local proc addrs
    proc="$(udp69_proc || true)"
    addrs="$(udp69_addrs || true)"
    if [ -n "$RUNNING_SVC" ]; then
        echo "[tftp] TFTP server: RUNNING ($RUNNING_SVC)"
        echo "[tftp]   listen : ${addrs:-<active unit, but no udp/69 listener found>}${proc:+ ($proc)}"
        echo "[tftp]   serves : ${SERVING_DIR:-<unknown — check its config>}"
        echo "[tftp]   config : $(server_conf "$RUNNING_SVC")"
    elif udp69_listening; then
        echo "[tftp] TFTP server: RUNNING (unrecognised daemon${proc:+: $proc})"
        echo "[tftp]   listen : ${addrs:-<unknown>}"
        echo "[tftp]            listening on udp/69, but not tftpd-hpa, atftpd, or a"
        echo "[tftp]            tftp-enabled dnsmasq — can't identify its config file."
    else
        echo "[tftp] TFTP server: NOT running (nothing listening on udp/69)"
    fi
    crosscheck_dir
}

install_hint() {
    echo "[tftp] No TFTP server is installed (or none configured to serve TFTP)." >&2
    echo "[tftp] Install one, e.g. on Debian/Ubuntu:" >&2
    echo "         sudo apt-get install tftpd-hpa" >&2
    echo "         # set TFTP_DIRECTORY in /etc/default/tftpd-hpa, then:" >&2
    echo "         sudo systemctl enable --now tftpd-hpa" >&2
    echo "[tftp] (dnsmasq is only auto-started here when 'enable-tftp' is in its config.)" >&2
}

cmd_status() {
    detect
    print_status
    exit 0
}

cmd_ensure() {
    detect
    if [ -n "$RUNNING_SVC" ]; then
        echo "[tftp] Already running ($RUNNING_SVC) — nothing to do."
        print_status
        exit 0
    fi
    if udp69_listening; then
        echo "[tftp] A TFTP server is already listening on udp/69 — nothing to do."
        print_status
        exit 0
    fi

    # Nothing running: pick an installed server we may start.
    local cand="" s
    for s in "${KNOWN_SERVERS[@]}"; do
        svc_present "$s" || continue
        if [ "$s" = dnsmasq ] && ! dnsmasq_tftp_enabled; then continue; fi
        cand="$s"
        break
    done

    if [ -z "$cand" ]; then
        install_hint
        exit 1
    fi

    echo "[tftp] No TFTP server running; starting $cand (needs sudo) ..."
    if ! sudo systemctl start "$cand"; then
        echo "[tftp] ERROR: 'sudo systemctl start $cand' failed." >&2
        echo "[tftp]        Inspect: systemctl status $cand ; journalctl -u $cand -e" >&2
        exit 1
    fi

    detect
    if [ -n "$RUNNING_SVC" ] || udp69_listening; then
        echo "[tftp] $cand is now running."
        echo "[tftp] (Persist across reboots with: sudo systemctl enable $cand)"
        print_status
        exit 0
    fi
    echo "[tftp] ERROR: started $cand but no udp/69 listener appeared." >&2
    echo "[tftp]        Check its config/logs: systemctl status $cand" >&2
    exit 1
}

# ------------------------------------------------------------- test subcommand

# Pick an available TFTP *client* (for `test`). Dedicated clients first; busybox's
# applet is the common fallback. Sets TFTP_CLIENT ("" if none found). Note curl
# only qualifies when tftp was compiled into its protocol list.
TFTP_CLIENT=""
pick_tftp_client() {
    if   have tftp;  then TFTP_CLIENT="tftp"
    elif have atftp; then TFTP_CLIENT="atftp"
    elif have curl && curl --version 2>/dev/null | grep -qiw tftp; then TFTP_CLIENT="curl"
    elif have busybox && busybox --list 2>/dev/null | grep -qx tftp; then TFTP_CLIENT="busybox"
    else TFTP_CLIENT=""
    fi
}

# tftp_get HOST REMOTE LOCAL — fetch REMOTE (path relative to the TFTP root) into
# LOCAL using $TFTP_CLIENT. Returns the client's exit status, but callers ALSO
# verify by output: the tftp-hpa client notoriously exits 0 even on failure.
tftp_get() {
    local host="$1" remote="$2" local="$3"
    case "$TFTP_CLIENT" in
        tftp)    tftp "$host" -m octet -c get "$remote" "$local" ;;
        atftp)   atftp --option "mode octet" --get -r "$remote" -l "$local" "$host" ;;
        curl)    curl -fsS -o "$local" "tftp://$host/$remote" ;;
        busybox) busybox tftp -g -r "$remote" -l "$local" "$host" ;;
        *)       return 127 ;;
    esac
}

# Host to fetch from: loopback when the server binds a wildcard (the usual case),
# else the specific bind address. Override with TFTP_TEST_HOST.
test_host() {
    if [ -n "${TFTP_TEST_HOST:-}" ]; then echo "$TFTP_TEST_HOST"; return 0; fi
    local first; first="$(udp69_addrs | sed 's/,.*//')"
    case "$first" in
        ""|0.0.0.0:*|\*:*|"[::]:"*) echo "127.0.0.1" ;;    # wildcard / unknown
        \[*\]:*)  local h="${first%]:*}"; echo "${h#[}" ;;  # [v6]:port -> v6
        *)        echo "${first%:*}" ;;                     # specific v4:port
    esac
}

cmd_test() {
    detect
    if [ -z "$RUNNING_SVC" ] && ! udp69_listening; then
        echo "[tftp] No TFTP server is running — nothing to test." >&2
        echo "[tftp]        Start one first:  make tftp-ensure" >&2
        exit 1
    fi

    local dir="${SERVING_DIR:-}" host
    host="$(test_host)"
    echo "[tftp] Retrieval test against $host (server: ${RUNNING_SVC:-unrecognised daemon})"

    # 1. List the served files. TFTP has NO directory-listing opcode (RFC 1350),
    #    so this is necessarily a filesystem view of the server's root directory.
    if [ -z "$dir" ]; then
        echo "[tftp]   (served dir unknown — cannot list files)"
    elif [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
        echo "[tftp]   (served dir $dir not readable by $(id -un) — cannot list files)"
    else
        echo "[tftp] Files in served dir $dir"
        echo "[tftp]   (filesystem view; TFTP itself cannot enumerate files):"
        (cd "$dir" && find . -type f -printf '         %10s  %P\n' 2>/dev/null | sort -k2) || true
        local nfiles
        nfiles="$( (cd "$dir" && find . -type f 2>/dev/null | wc -l) || echo 0)"
        echo "[tftp]   $nfiles file(s) total"
    fi

    # 2. Need a client to actually fetch.
    pick_tftp_client
    if [ -z "$TFTP_CLIENT" ]; then
        echo "[tftp] FAIL: no TFTP client installed to test retrieval." >&2
        echo "[tftp]        install one:  sudo apt-get install tftp-hpa   # or atftp" >&2
        exit 1
    fi

    # 3. Choose a file: TFTP_TEST_FILE if given, else the smallest non-empty one.
    local remote="${TFTP_TEST_FILE:-}"
    if [ -z "$remote" ] && [ -n "$dir" ] && [ -r "$dir" ]; then
        remote="$(cd "$dir" && find . -type f -size +0c -printf '%s\t%P\n' 2>/dev/null \
                    | sort -n | head -1 | cut -f2-)"
    fi
    if [ -z "$remote" ]; then
        echo "[tftp] FAIL: no non-empty file to retrieve (served dir empty/unreadable)." >&2
        echo "[tftp]        stage boot files first (make tftp), or set TFTP_TEST_FILE=<name>." >&2
        exit 1
    fi

    # 4. Fetch into a temp file and verify by OUTPUT (not just the exit status).
    local tmp out rc=0
    tmp="$(mktemp)"
    echo "[tftp] Fetching '$remote' via $TFTP_CLIENT from $host ..."
    out="$(tftp_get "$host" "$remote" "$tmp" 2>&1)" || rc=$?

    if [ ! -s "$tmp" ]; then
        echo "[tftp] FAIL: '$remote' came back empty or was not created (client rc=$rc)." >&2
        if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/[tftp]        /' >&2; fi
        rm -f "$tmp"; exit 1
    fi

    local got src; got="$(stat -c %s "$tmp" 2>/dev/null || echo '?')"; src="$dir/$remote"
    if [ -n "$dir" ] && [ -r "$src" ]; then
        if cmp -s "$src" "$tmp"; then
            echo "[tftp] PASS: retrieved '$remote' ($got bytes) — byte-exact match with source."
            rm -f "$tmp"; exit 0
        fi
        echo "[tftp] FAIL: '$remote' retrieved ($got bytes) but differs from the source file." >&2
        rm -f "$tmp"; exit 1
    fi
    echo "[tftp] PASS: retrieved '$remote' ($got bytes)  [source not readable for byte-compare]."
    rm -f "$tmp"; exit 0
}

case "$SUBCMD" in
    status) cmd_status ;;
    ensure) cmd_ensure ;;
    test)   cmd_test ;;
    -h|--help)
        echo "Usage: tftp-server.sh {status|ensure|test} [--tftp-dir DIR]"
        exit 0
        ;;
    "") echo "Usage: tftp-server.sh {status|ensure|test} [--tftp-dir DIR]" >&2; exit 1 ;;
    *)  echo "tftp-server.sh: unknown subcommand: $SUBCMD (use status|ensure|test)" >&2; exit 1 ;;
esac

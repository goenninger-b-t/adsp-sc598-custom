#!/usr/bin/env bash
#
# distro-info.sh - print the Yocto DISTRO identity (name / version / codename)
# and the build context, queried LIVE from bitbake so it reflects the actual
# configured build (config.mk + overlays), not a hardcoded guess.
#
# Must run with the bitbake environment already sourced - the Makefile's
# `distro-info` target does that (cd src && source setup-environment && this).
# `bitbake -e` parses the configuration, so the first run can take ~10-30 s
# (faster once the parse cache is warm).
#
# PORTABILITY: any Yocto/OE build; needs bitbake on PATH (i.e. the sourced env).

set -euo pipefail

MACHINE=""
IMAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --machine) MACHINE="$2"; shift 2 ;;
        --image)   IMAGE="$2";   shift 2 ;;
        *) echo "distro-info.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

if ! command -v bitbake >/dev/null 2>&1; then
    echo "[distro-info] ERROR: bitbake not on PATH." >&2
    echo "[distro-info]        Run via 'make distro-info' (it sources the build env)." >&2
    exit 1
fi

echo "[distro-info] Querying the bitbake environment (can take ~10-30s) ..."
ENVFILE="$(mktemp)"
trap 'rm -f "$ENVFILE"' EXIT
if ! bitbake -e > "$ENVFILE" 2>"$ENVFILE.err"; then
    echo "[distro-info] ERROR: 'bitbake -e' failed - is the build configured?" >&2
    echo "[distro-info]        Run 'make image' (or 'make configure') first. Details:" >&2
    tail -5 "$ENVFILE.err" >&2 2>/dev/null || true
    rm -f "$ENVFILE.err"
    exit 1
fi
rm -f "$ENVFILE.err"

# v VAR -> the resolved value of VAR from `bitbake -e` (handles optional `export`)
v() { sed -n "s/^\(export \)\?$1=\"\(.*\)\"\$/\2/p" "$ENVFILE" | head -1; }

DISTRO="$(v DISTRO)"
DNAME="$(v DISTRO_NAME)"
DVER="$(v DISTRO_VERSION)"
DCODE="$(v DISTRO_CODENAME)"
SERIES="$(v LAYERSERIES_CORENAMES)"
BBV="$(v BB_VERSION)"; [ -n "$BBV" ] || BBV="$(bitbake --version 2>/dev/null | sed -n '1s/.*version //p')"

echo
echo "==================== Yocto distro ===================="
printf '  %-20s %s\n' "Distro (DISTRO)"     "$DISTRO"
printf '  %-20s %s\n' "Name"                "$DNAME"
printf '  %-20s %s\n' "Version"             "$DVER"
printf '  %-20s %s\n' "Codename"            "$DCODE"
printf '  %-20s %s\n' "Pretty name"         "$DNAME $DVER ($DCODE)"
printf '  %-20s %s\n' "OE release series"   "$SERIES"
printf '  %-20s %s\n' "C library (TCLIBC)"  "$(v TCLIBC)"
printf '  %-20s %s\n' "SDK_VERSION"         "$(v SDK_VERSION)"

echo
echo "==================== Build context ===================="
printf '  %-20s %s\n' "MACHINE"             "${MACHINE:-$(v MACHINE)}"
printf '  %-20s %s\n' "Default image"       "$IMAGE"
printf '  %-20s %s\n' "TARGET_SYS"          "$(v TARGET_SYS)"
printf '  %-20s %s\n' "DEFAULTTUNE"         "$(v DEFAULTTUNE)"
printf '  %-20s %s\n' "bitbake version"     "$BBV"
printf '  %-20s %s\n' "Build host"          "$(v BUILD_SYS)"

echo
echo "  DISTRO_FEATURES:"
echo "    $(v DISTRO_FEATURES)"

echo
echo "==================== Layers (BBLAYERS) ===================="
for L in $(v BBLAYERS); do
    printf '  %s\n' "$L"
done

echo
echo "[distro-info] (live from 'bitbake -e'; cross-checks the image's /etc/os-release)"

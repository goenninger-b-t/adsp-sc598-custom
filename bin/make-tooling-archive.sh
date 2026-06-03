#!/usr/bin/env bash
# make-tooling-archive.sh - build a self-extracting shell archive of the
# ADSP-SC598 build tooling: Makefile, config.mk, .gitignore, bin/, overlays/,
# and the src/apps/hello-world example. The fetched ADI BSP (src/.repo,
# src/sources, src/build, ...) is deliberately NOT included.
#
# The output is a POSIX /bin/sh script with a gzip tarball appended after a
# marker line. Running it verifies an embedded SHA-256, then extracts the tree
# (see `sh <archive> --help` for its options).
#
# Usage:
#   bin/make-tooling-archive.sh             # -> tooling/adsp-sc598-tooling.sh
#   bin/make-tooling-archive.sh -o /tmp/x.sh
set -euo pipefail

# --- locate the project root (this script lives in <root>/bin/) -------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$SCRIPT_DIR")"
SELFNAME="${BASH_SOURCE[0]##*/}"

# --- what goes in the archive (relative to ROOT; dirs are recursed by tar) --
ARCHIVE_NAME="adsp-sc598-tooling.sh"
MARKER="__ADSP_SC598_TOOLING_PAYLOAD__"
ITEMS=(Makefile config.mk .gitignore bin overlays src/apps)

OUT="$ROOT/tooling/$ARCHIVE_NAME"

usage() {
    cat <<USAGE
Usage: $SELFNAME [-o OUTPUT] [-h]

Builds a self-extracting archive of the project tooling.

  -o OUTPUT   Write the archive here (default: $OUT)
  -h          Show this help.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUT="${2:?-o needs a path}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "$SELFNAME: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# --- sanity checks ----------------------------------------------------------
missing=0
for it in "${ITEMS[@]}"; do
    if [ ! -e "$ROOT/$it" ]; then
        echo "$SELFNAME: missing required item: $it" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1
command -v sha256sum >/dev/null 2>&1 || { echo "$SELFNAME: sha256sum required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. payload tarball: deterministic order, no owner/username leakage ------
TAR_COMMON=(--owner=0 --group=0 --numeric-owner -czf "$TMP/payload.tgz" -C "$ROOT")
if ! tar --sort=name "${TAR_COMMON[@]}" "${ITEMS[@]}" 2>/dev/null; then
    tar "${TAR_COMMON[@]}" "${ITEMS[@]}"
fi

# --- 2. metadata embedded in the header -------------------------------------
SHA="$(sha256sum "$TMP/payload.tgz" | cut -d' ' -f1)"
PAYLOAD_BYTES="$(stat -c%s "$TMP/payload.tgz")"
FILE_COUNT="$(tar -tzf "$TMP/payload.tgz" | grep -vc '/$' || true)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 3. header = dynamic lines (printf) + literal extractor body (heredoc) ---
# ARCHIVE_NAME / MARKER / EXPECTED_SHA256 are emitted here so they have a
# single source of truth; the quoted <<'EOF' body is pure runtime sh code.
{
  printf '#!/bin/sh\n'
  printf '#\n'
  printf '# %s - self-extracting archive of the ADSP-SC598 Yocto build tooling.\n' "$ARCHIVE_NAME"
  printf '# Contents: Makefile, config.mk, .gitignore, bin/, overlays/, and the\n'
  printf '# src/apps/hello-world example. Does NOT include the fetched ADI BSP\n'
  printf '# (run `make init && make fetch` after extracting to pull that).\n'
  printf '#\n'
  printf '# Built (UTC): %s\n' "$BUILD_DATE"
  printf '# Payload    : %s files, %s bytes gzip\n' "$FILE_COUNT" "$PAYLOAD_BYTES"
  printf '#\n'
  printf '# Usage: sh %s --help    (do NOT edit: a binary payload is appended below)\n' "$ARCHIVE_NAME"
  printf '#\n'
  printf "ARCHIVE_NAME='%s'\n" "$ARCHIVE_NAME"
  printf "MARKER='%s'\n" "$MARKER"
  printf 'EXPECTED_SHA256=%s\n' "$SHA"
  cat <<'EOF'
SELF="$0"

usage() {
    cat <<USAGE
$ARCHIVE_NAME - self-extracting archive of the ADSP-SC598 build tooling.

Usage:
  sh $SELF [options]

Options:
  -C DIR, --dir DIR   Extract into DIR (default: current directory; created if
                      missing). Existing files are NOT overwritten unless -f.
  -l, --list          List the archived files and exit.
  -t, --check         Verify the embedded SHA-256 of the payload and exit.
  -f, --force         Overwrite existing files in the target directory.
  -h, --help          Show this help and exit.

After extracting:  cd DIR && make init && make fetch && make image
USAGE
}

have() { command -v "$1" >/dev/null 2>&1; }

sha256_stdin() {
    if   have sha256sum; then sha256sum | cut -d' ' -f1
    elif have shasum;    then shasum -a 256 | cut -d' ' -f1
    elif have openssl;   then openssl dgst -sha256 | sed 's/.*= *//'
    else return 1
    fi
}

DIR=.
DO_LIST=0
DO_CHECK=0
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -C|--dir)          DIR="${2:?--dir needs an argument}"; shift 2 ;;
        -l|--list)         DO_LIST=1; shift ;;
        -t|--check|--test) DO_CHECK=1; shift ;;
        -f|--force)        FORCE=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; break ;;
        *) printf '%s: unknown option: %s\n' "$ARCHIVE_NAME" "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ ! -f "$SELF" ]; then
    printf '%s: must be run as a file, e.g. `sh %s` (not piped via stdin).\n' "$ARCHIVE_NAME" "$SELF" >&2
    exit 1
fi

START=$(awk "/^${MARKER}\$/ { print NR + 1; exit }" "$SELF")
if [ -z "${START:-}" ]; then
    printf '%s: payload marker not found - archive corrupt?\n' "$ARCHIVE_NAME" >&2
    exit 1
fi

verify() {
    _actual=$(tail -n +"$START" "$SELF" | sha256_stdin) || {
        printf '%s: no sha256 tool (sha256sum/shasum/openssl); skipping integrity check.\n' "$ARCHIVE_NAME" >&2
        return 0
    }
    if [ "$_actual" != "$EXPECTED_SHA256" ]; then
        printf '%s: CHECKSUM MISMATCH\n  expected %s\n  actual   %s\n' "$ARCHIVE_NAME" "$EXPECTED_SHA256" "$_actual" >&2
        return 1
    fi
    return 0
}

if [ "$DO_CHECK" -eq 1 ]; then
    if verify; then printf 'OK: payload sha256 = %s\n' "$EXPECTED_SHA256"; exit 0; fi
    exit 1
fi

if [ "$DO_LIST" -eq 1 ]; then
    tail -n +"$START" "$SELF" | tar -tzf -
    exit 0
fi

verify || exit 1
mkdir -p "$DIR"

if [ "$FORCE" -ne 1 ]; then
    conflicts=$(tail -n +"$START" "$SELF" | tar -tzf - | while IFS= read -r f; do
        case "$f" in */) continue ;; esac
        if [ -e "$DIR/$f" ]; then printf '  %s\n' "$f"; fi
    done)
    if [ -n "$conflicts" ]; then
        printf '%s: refusing to overwrite existing files in %s:\n%s\n' "$ARCHIVE_NAME" "$DIR" "$conflicts" >&2
        printf 'Re-run with -f to overwrite, or pick another dir with -C DIR.\n' >&2
        exit 1
    fi
fi

tail -n +"$START" "$SELF" | tar -xzf - -C "$DIR"
printf 'Extracted ADSP-SC598 tooling into: %s\n' "$DIR"
printf 'Next: cd %s && make init && make fetch && make image\n' "$DIR"
exit 0
EOF
  printf '%s\n' "$MARKER"
} > "$TMP/header.sh"

# --- 4. assemble: header text (ending in the marker line) + binary payload ---
mkdir -p "$(dirname -- "$OUT")"
cat "$TMP/header.sh" "$TMP/payload.tgz" > "$OUT"
chmod +x "$OUT"

printf 'built %s\n  size   : %s bytes\n  files  : %s\n  sha256 : %s\n' \
  "$OUT" "$(stat -c%s "$OUT")" "$FILE_COUNT" "$SHA"

#!/usr/bin/env bash
# repo-init.sh - Bootstrap the ADI BSP source tree (backs `make init`).
#
# Two steps, in order:
#   1. Download Google's `repo` launcher binary into <src-dir>/bin/repo.
#   2. Run `repo init` against the Analog Devices manifest, writing
#      <src-dir>/.repo/ and selecting which manifest/branch to sync.
#
# It deliberately does NOT run `repo sync` - pulling the actual sources is
# `make fetch`'s job. All inputs are supplied by the top-level Makefile from
# config.mk; see config.mk for per-variable documentation.
set -euo pipefail

SRC_DIR=""
REPO_TOOL_URL=""
MANIFEST_URL=""
MANIFEST_BRANCH=""
MANIFEST_FILE=""

usage() {
	cat >&2 <<'EOF'
Usage: repo-init.sh --src-dir DIR --repo-tool-url URL \
                    --manifest-url URL --manifest-branch BRANCH \
                    --manifest-file FILE.xml

All arguments are required and are normally passed by `make init` from the
values in config.mk (REPO_TOOL_URL, REPO_MANIFEST_URL, REPO_MANIFEST_BRANCH,
REPO_MANIFEST_FILE).
EOF
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--src-dir)         SRC_DIR="${2:-}"; shift 2 ;;
		--repo-tool-url)   REPO_TOOL_URL="${2:-}"; shift 2 ;;
		--manifest-url)    MANIFEST_URL="${2:-}"; shift 2 ;;
		--manifest-branch) MANIFEST_BRANCH="${2:-}"; shift 2 ;;
		--manifest-file)   MANIFEST_FILE="${2:-}"; shift 2 ;;
		-h|--help)         usage ;;
		*) echo "repo-init.sh: unknown argument: $1" >&2; usage ;;
	esac
done

missing=0
for v in SRC_DIR REPO_TOOL_URL MANIFEST_URL MANIFEST_BRANCH MANIFEST_FILE; do
	if [ -z "${!v}" ]; then
		echo "repo-init.sh: missing required value for $v" >&2
		missing=1
	fi
done
[ "$missing" -eq 0 ] || usage

REPO_BIN="$SRC_DIR/bin/repo"

echo "[init] src dir         : $SRC_DIR"
echo "[init] repo tool url    : $REPO_TOOL_URL"
echo "[init] manifest url     : $MANIFEST_URL"
echo "[init] manifest branch  : $MANIFEST_BRANCH"
echo "[init] manifest file    : $MANIFEST_FILE"

# --- 1. fetch the `repo` launcher -----------------------------------------
mkdir -p "$SRC_DIR/bin"
echo "[init] downloading repo launcher -> $REPO_BIN"
# -f: fail (non-zero) on HTTP errors instead of saving the error page
# -S: still show the error message when -s would otherwise hide it
# -L: follow redirects (Google may 30x http -> https)
# -o: write to file
curl -fSL "$REPO_TOOL_URL" -o "$REPO_BIN"
chmod a+x "$REPO_BIN"

# Sanity-check: the launcher is a Python script and must start with a shebang.
# `curl -f` catches 4xx/5xx, but a captive portal / proxy can still return a
# 200 with an HTML body - reject that here rather than exec'ing garbage.
if ! head -n1 "$REPO_BIN" | grep -q '^#!'; then
	echo "[init] ERROR: downloaded file does not start with a '#!' shebang." >&2
	echo "[init]        REPO_TOOL_URL probably returned an error/HTML page." >&2
	echo "[init]        REPO_TOOL_URL=$REPO_TOOL_URL" >&2
	exit 1
fi

# --- 2. repo init ----------------------------------------------------------
echo "[init] running repo init"
cd "$SRC_DIR"
./bin/repo init \
	-u "$MANIFEST_URL" \
	-b "$MANIFEST_BRANCH" \
	-m "$MANIFEST_FILE"

echo "[init] done - manifest initialised under $SRC_DIR/.repo"
echo "[init] next: run 'make fetch' to repo sync the BSP sources."

#!/usr/bin/env bash
# Publish the generated SD-card image as a GitHub release asset.
#
# Uses the `gh` CLI. Authenticate beforehand via `gh auth login` or by exporting
# GH_TOKEN. The target repo must already exist on GitHub.
#
# Prefers the deploy-dir .wic.gz (already compressed, smaller upload) over the
# decompressed output/sdcard.img. Falls back to whichever exists.

set -euo pipefail

REPO=""
PROJECT=""
VERSION=""
TARGET="main"
MACHINE=""
IMAGE_NAME=""
DEPLOY_DIR=""
IMAGES_DIR=""
NOTES_FILE=""
DRAFT=""
PRERELEASE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)        REPO="$2";        shift 2 ;;
        --project)     PROJECT="$2";     shift 2 ;;
        --version)     VERSION="$2";     shift 2 ;;
        --target)      TARGET="$2";      shift 2 ;;
        --machine)     MACHINE="$2";     shift 2 ;;
        --image-name)  IMAGE_NAME="$2";  shift 2 ;;
        --deploy-dir)  DEPLOY_DIR="$2";  shift 2 ;;
        --images-dir)  IMAGES_DIR="$2";  shift 2 ;;
        --notes-file)  NOTES_FILE="$2";  shift 2 ;;
        --draft)       DRAFT=1;          shift ;;
        --prerelease)  PRERELEASE=1;     shift ;;
        *) echo "publish-release.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$REPO" ]    || { echo "ERROR: --repo (GH_REPO) required (owner/repo)" >&2; exit 1; }
[ -n "$VERSION" ] || { echo "ERROR: --version (GH_VERSION) required (e.g. 1.0.0)" >&2; exit 1; }
[ -n "$PROJECT" ] || PROJECT="$(basename "$REPO")"

# Validate GH_VERSION against strict Semantic Versioning 2.0.0.
# Spec: https://semver.org/spec/v2.0.0.html
#
# The regex is the canonical PCRE from semver.org translated to POSIX ERE
# (no \d, no named groups). The "v" prefix is REJECTED: per the semver.org
# FAQ, "v1.2.3" is not a semantic version - it is at best a tag name whose
# underlying semver is "1.2.3". This project requires the canonical form.
#
# Grammar enforced:
#   MAJOR . MINOR . PATCH [ - PRERELEASE ] [ + BUILDMETA ]
# where MAJOR/MINOR/PATCH are non-negative ints with no leading zeros,
# PRERELEASE / BUILDMETA are dot-separated identifiers of [0-9A-Za-z-],
# numeric PRERELEASE identifiers may not have leading zeros, identifiers
# may not be empty.
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(\+([0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*))?$'

if ! [[ "$VERSION" =~ $SEMVER_RE ]]; then
    {
        echo "ERROR: GH_VERSION '$VERSION' is not valid Semantic Versioning 2.0.0."
        echo ""
        echo "       Expected: MAJOR.MINOR.PATCH[-prerelease][+buildmetadata]"
        echo "       The 'v' prefix is NOT allowed - use the canonical semver form."
        echo ""
        echo "       Valid examples:"
        echo "         1.0.0"
        echo "         0.1.0"
        echo "         1.0.0-rc.1"
        echo "         1.0.0-alpha+exp.sha.5114f85"
        echo "         2.0.0-rc.2+build.42"
        echo ""
        echo "       Common mistakes:"
        echo "         v1.0.0        (the 'v' prefix is forbidden)"
        echo "         1.0           (missing PATCH)"
        echo "         1             (missing MINOR and PATCH)"
        echo "         01.0.0        (leading zero in MAJOR)"
        echo "         1.0.0-        (empty prerelease)"
        echo "         1.0.0_beta    (underscore not allowed in identifiers)"
        echo ""
        echo "       Spec: https://semver.org/spec/v2.0.0.html"
    } >&2
    exit 1
fi

# Pre-flight: gh CLI installed and authenticated.
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: 'gh' (GitHub CLI) is not installed."
    echo "       Install it from https://cli.github.com/  (Debian/Ubuntu: 'sudo apt install gh')"
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated. Run 'gh auth login' or export GH_TOKEN."
    exit 1
fi

# Locate the source image. Prefer wic.gz (compressed, smaller upload).
# Search order: images/ (set by `make image`) -> bitbake deploy dir -> images/sdcard.img.
# Yocto Scarthgap names produce a .rootfs.wic.gz; older / non-rootfs images
# may drop the .rootfs. infix - try both.
SRC=""
EXT=""
for d in "$IMAGES_DIR" "$DEPLOY_DIR"; do
    [ -n "$d" ] && [ -n "$IMAGE_NAME" ] && [ -n "$MACHINE" ] || continue
    for f in "$d/${IMAGE_NAME}-${MACHINE}.rootfs.wic.gz" \
             "$d/${IMAGE_NAME}-${MACHINE}.wic.gz"; do
        if [ -f "$f" ]; then SRC="$f"; EXT="wic.gz"; break 2; fi
    done
done
if [ -z "$SRC" ] && [ -n "$IMAGES_DIR" ] && [ -f "$IMAGES_DIR/sdcard.img" ]; then
    SRC="$IMAGES_DIR/sdcard.img"
    EXT="img"
fi
if [ -z "$SRC" ]; then
    echo "ERROR: no image found." >&2
    echo "  Looked for: $IMAGES_DIR/${IMAGE_NAME}-${MACHINE}{.rootfs,}.wic.gz" >&2
    echo "         and: $DEPLOY_DIR/${IMAGE_NAME}-${MACHINE}{.rootfs,}.wic.gz" >&2
    echo "         and: $IMAGES_DIR/sdcard.img" >&2
    echo "  Run 'make image' (and optionally 'make sdcard') first." >&2
    exit 1
fi

[ -n "$IMAGES_DIR" ] || { echo "ERROR: --images-dir required" >&2; exit 1; }
mkdir -p "$IMAGES_DIR"

# Stage versioned asset directly in images/ so it persists after publish.
# Tempdir is used only for transient files (auto-generated release notes).
WORK=$(mktemp -d)
trap "rm -rf '$WORK'" EXIT

ASSET_NAME="${PROJECT}-${MACHINE:-image}-${VERSION}.${EXT}"
ASSET_PATH="$IMAGES_DIR/$ASSET_NAME"
SHA_PATH="$IMAGES_DIR/${ASSET_NAME}.sha256"

# Only copy if source != destination (the source IS already the staged file
# from a previous run, e.g. when re-publishing).
if [ "$(realpath "$SRC")" != "$(realpath "$ASSET_PATH" 2>/dev/null || echo NONE)" ]; then
    cp -L "$SRC" "$ASSET_PATH"
fi

# SHA256 sidecar (relative-name format so `sha256sum -c` works in images/)
( cd "$IMAGES_DIR" && sha256sum "$ASSET_NAME" > "${ASSET_NAME}.sha256" )
SHA256="$(cut -d' ' -f1 "$SHA_PATH")"
SIZE_H="$(du -h "$ASSET_PATH" | cut -f1)"

# Default release notes if user didn't supply --notes-file.
if [ -z "$NOTES_FILE" ]; then
    NOTES_FILE="$WORK/notes.md"
    {
        echo "# ${PROJECT} ${VERSION}"
        echo ""
        echo "ADSP-SC598 Yocto SD-card image."
        echo ""
        echo "| Field        | Value |"
        echo "|--------------|-------|"
        echo "| Machine      | \`${MACHINE:-unknown}\` |"
        echo "| Image recipe | \`${IMAGE_NAME:-unknown}\` |"
        echo "| Asset        | \`${ASSET_NAME}\` |"
        echo "| Size         | ${SIZE_H} |"
        echo "| SHA256       | \`${SHA256}\` |"
        echo "| Built on     | $(date -u +%Y-%m-%dT%H:%M:%SZ) |"
        echo ""
        if [ "$EXT" = "wic.gz" ]; then
            echo "## Flashing"
            echo ""
            echo '```sh'
            echo "gunzip -kc ${ASSET_NAME} | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync"
            echo "sync"
            echo '```'
        fi
    } > "$NOTES_FILE"
fi

echo "[publish] repo    : $REPO"
echo "[publish] tag     : $VERSION"
echo "[publish] target  : $TARGET"
echo "[publish] asset   : $ASSET_NAME (${SIZE_H})"
echo "[publish] sha256  : $SHA256"

FLAGS=()
[ -n "$DRAFT" ]      && FLAGS+=(--draft)
[ -n "$PRERELEASE" ] && FLAGS+=(--prerelease)

if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "[publish] release $VERSION already exists - uploading assets with --clobber"
    gh release upload "$VERSION" --repo "$REPO" --clobber \
        "$ASSET_PATH" "$SHA_PATH"
else
    echo "[publish] creating release $VERSION (target=$TARGET)"
    gh release create "$VERSION" --repo "$REPO" \
        --target "$TARGET" \
        --title "${PROJECT} ${VERSION}" \
        --notes-file "$NOTES_FILE" \
        "${FLAGS[@]}" \
        "$ASSET_PATH" "$SHA_PATH"
fi

echo "[publish] staged in $IMAGES_DIR/:"
echo "[publish]   $ASSET_NAME"
echo "[publish]   ${ASSET_NAME}.sha256"

URL="$(gh release view "$VERSION" --repo "$REPO" --json url -q .url 2>/dev/null || true)"
echo "[publish] Done."
[ -n "$URL" ] && echo "[publish] $URL"

#!/usr/bin/env bash
# Configure the bitbake build directory: source ADI setup-environment if needed,
# then idempotently apply overlays/local.conf.fragment and overlays/bblayers.conf.fragment.
#
# Re-running this script is safe and a no-op once overlays are in place.
set -euo pipefail

# Refuse to run as root: writing the build dir / generated layer as root leaves
# root-owned files the normal user cannot later regenerate, and bitbake won't run
# as root anyway. Override with ADSP_ALLOW_ROOT=1 for a deliberate container build.
if [ "$(id -u)" -eq 0 ] && [ "${ADSP_ALLOW_ROOT:-}" != "1" ]; then
    echo "configure-build.sh: refusing to run as root - re-run without sudo." >&2
    echo "  (Override: ADSP_ALLOW_ROOT=1 if you really mean it.)" >&2
    exit 1
fi

PROJECT_ROOT=""
BUILDDIR="build"
MACHINE=""
DISTRO=""
SOM_REV=""
CRR_REV=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root) PROJECT_ROOT="$2"; shift 2 ;;
        --builddir)     BUILDDIR="$2";     shift 2 ;;
        --machine)      MACHINE="$2";      shift 2 ;;
        --distro)       DISTRO="$2";       shift 2 ;;
        --som-rev)      SOM_REV="$2";      shift 2 ;;
        --crr-rev)      CRR_REV="$2";      shift 2 ;;
        *) echo "configure-build.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$PROJECT_ROOT" ] || { echo "configure-build.sh: --project-root required" >&2; exit 1; }
[ -n "$MACHINE" ]      || { echo "configure-build.sh: --machine required" >&2; exit 1; }
[ -n "$DISTRO" ]       || { echo "configure-build.sh: --distro required" >&2; exit 1; }

SRC_DIR="$PROJECT_ROOT/src"
BUILD_DIR="$SRC_DIR/$BUILDDIR"
OVERLAYS_DIR="$PROJECT_ROOT/overlays"
LAYER_DIR="$SRC_DIR/layers/meta-custom-apps"

if [ ! -d "$SRC_DIR/sources" ]; then
    echo "[configure] ERROR: $SRC_DIR/sources/ missing - run 'make fetch' first." >&2
    exit 1
fi

if [ ! -e "$BUILD_DIR/conf/local.conf" ]; then
    echo "[configure] First-time setup: machine=$MACHINE distro=$DISTRO builddir=$BUILDDIR"
    # Sourcing setup-environment must happen from src/; do it in a subshell so the script's
    # internal vars and unset behaviour don't leak into the caller.
    (
        cd "$SRC_DIR"
        # poky's oe-init-build-env touches $BBSERVER/$ZSH_NAME without defaults;
        # relax nounset in this subshell only.
        set +u
        # shellcheck source=/dev/null
        source ./setup-environment --machine "$MACHINE" --distro "$DISTRO" --builddir "$BUILDDIR" >/dev/null
    )
fi

# Ensure the placeholder layer exists so bitbake parsing doesn't fail before `make apps` runs.
mkdir -p "$LAYER_DIR/conf"
if [ ! -e "$LAYER_DIR/conf/layer.conf" ]; then
    cat > "$LAYER_DIR/conf/layer.conf" <<'EOF'
# Placeholder layer.conf - will be overwritten by bin/gen-apps.py on `make apps`.
BBPATH .= ":${LAYERDIR}"
BBFILES += "${LAYERDIR}/recipes-*/*/*.bb ${LAYERDIR}/recipes-*/*/*.bbappend"
BBFILE_COLLECTIONS += "custom-apps"
BBFILE_PATTERN_custom-apps = "^${LAYERDIR}/"
BBFILE_PRIORITY_custom-apps = "10"
LAYERSERIES_COMPAT_custom-apps = "scarthgap"
EOF
fi

apply_overlay() {
    local target="$1"
    local fragment="$2"
    local begin="# === BEGIN custom-apps overlay ==="
    local end="# === END custom-apps overlay ==="

    if [ ! -e "$target" ]; then
        echo "[configure] ERROR: $target missing" >&2
        exit 1
    fi
    if [ ! -e "$fragment" ]; then
        echo "[configure] ERROR: overlay fragment $fragment missing" >&2
        exit 1
    fi

    # Replace semantics: if a previous overlay block exists, drop it first,
    # then append the current fragment. Keeps overlays in sync with source.
    if grep -qF "$begin" "$target"; then
        echo "[configure] refreshing overlay in $(basename "$target")"
        sed -i "/$begin/,/$end/d" "$target"
    else
        echo "[configure] adding overlay to $(basename "$target")"
    fi
    printf '\n' >> "$target"
    cat "$fragment" >> "$target"
}

# Inject the hardware-revision selectors (ADI getting-started: "Check and select
# the appropriate revision") into the local.conf overlay block, just before its
# END marker - so they live inside the managed block and are regenerated on every
# configure (no duplication on re-run). Only emitted when set; unset -> the BSP
# default, which ADI documents as valid for SOM Rev A/B/C/D, EZ-Kit Carrier rev D.
inject_revisions() {
    local target="$1"
    local end="# === END custom-apps overlay ==="
    local block=""
    if [ -n "$SOM_REV" ]; then block+="SOM_REV = \"$SOM_REV\""$'\n'; fi
    if [ -n "$CRR_REV" ]; then block+="CRR_REV = \"$CRR_REV\""$'\n'; fi
    [ -n "$block" ] || return 0
    local tmp; tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$end" ]; then
            printf '# Hardware revision selectors (SOM_REV / CRR_REV) - see config.mk.\n'
            printf '%s' "$block"
        fi
        printf '%s\n' "$line"
    done < "$target" > "$tmp"
    cat "$tmp" > "$target"   # overwrite content, preserve the file's perms
    rm -f "$tmp"
    echo "[configure] hardware revision -> ${SOM_REV:+SOM_REV=\"$SOM_REV\" }${CRR_REV:+CRR_REV=\"$CRR_REV\"}"
}

apply_overlay "$BUILD_DIR/conf/local.conf"    "$OVERLAYS_DIR/local.conf.fragment"
inject_revisions "$BUILD_DIR/conf/local.conf"
apply_overlay "$BUILD_DIR/conf/bblayers.conf" "$OVERLAYS_DIR/bblayers.conf.fragment"

echo "[configure] Done."
echo "[configure]   build dir : $BUILD_DIR"
echo "[configure]   machine   : $MACHINE"
echo "[configure]   distro    : $DISTRO"
echo "[configure]   som/crr   : ${SOM_REV:-<BSP default>} / ${CRR_REV:-<BSP default>}"
echo "[configure]   layer dir : $LAYER_DIR"

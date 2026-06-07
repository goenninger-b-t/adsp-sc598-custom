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
LINUX_MEM=""
DDR_SIZE=""
DDR_BASE=""
BOARD_DNS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root) PROJECT_ROOT="$2"; shift 2 ;;
        --builddir)     BUILDDIR="$2";     shift 2 ;;
        --machine)      MACHINE="$2";      shift 2 ;;
        --distro)       DISTRO="$2";       shift 2 ;;
        --som-rev)      SOM_REV="$2";      shift 2 ;;
        --crr-rev)      CRR_REV="$2";      shift 2 ;;
        --linux-mem)    LINUX_MEM="$2";    shift 2 ;;
        --ddr-size)     DDR_SIZE="$2";     shift 2 ;;
        --ddr-base)     DDR_BASE="$2";     shift 2 ;;
        --board-dns)    BOARD_DNS="$2";    shift 2 ;;
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

# Parse a memory size (224M / 512M / 1G / 1024K / 0x.. / decimal) -> bytes.
mem_to_bytes() {
    local v; v="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    case "$v" in
        *g) echo $(( ${v%g} * 1073741824 )) ;;
        *m) echo $(( ${v%m} * 1048576 )) ;;
        *k) echo $(( ${v%k} * 1024 )) ;;
        0x*|[0-9]*) echo $(( v )) ;;
        *) echo "[configure] ERROR: bad memory size '$1'" >&2; exit 1 ;;
    esac
}

# Validate LINUX_MEM against physical DDR + the FIT DTB load address, compute the
# Linux DDR window (Linux at the TOP of DDR; the SHARC+ cores get the rest), and
# inject LINUX_MEM / LINUX_MEM_BASE / LINUX_MEM_SIZE into the managed local.conf
# block for the meta-custom-bsp linux-adi bbappend. Only emitted when set.
inject_linux_mem() {
    local target="$1"
    [ -n "$LINUX_MEM" ] || return 0
    local end="# === END custom-apps overlay ==="
    local ddrbase ddrsize linuxsize top fitfdt lbase
    ddrbase="$(mem_to_bytes "${DDR_BASE:-0x80000000}")"
    ddrsize="$(mem_to_bytes "${DDR_SIZE:-512M}")"
    linuxsize="$(mem_to_bytes "$LINUX_MEM")"
    top=$(( ddrbase + ddrsize ))
    fitfdt=$(( 0x99000000 ))   # FIT kernel-DTB load address (fit-image.its)

    [ "$linuxsize" -gt 0 ] || { echo "[configure] ERROR: LINUX_MEM ('$LINUX_MEM') must be > 0" >&2; exit 1; }
    if [ "$linuxsize" -gt "$ddrsize" ]; then
        echo "[configure] ERROR: LINUX_MEM ($LINUX_MEM) exceeds physical DDR_SIZE ($DDR_SIZE)." >&2
        exit 1
    fi
    lbase=$(( top - linuxsize ))
    if [ "$lbase" -gt "$fitfdt" ]; then
        echo "[configure] ERROR: LINUX_MEM ($LINUX_MEM) too small - Linux base $(printf '0x%08x' "$lbase") would sit above the FIT kernel-DTB load address 0x99000000 (boot would fail). Increase LINUX_MEM (min ~112M)." >&2
        exit 1
    fi

    local base_hex size_hex base_node sharc_mb
    base_hex="$(printf '0x%08x' "$lbase")"
    size_hex="$(printf '0x%08x' "$linuxsize")"
    base_node="${base_hex#0x}"   # DT node unit-address (no 0x), e.g. memory@92000000
    sharc_mb=$(( (ddrsize - linuxsize) / 1048576 ))

    local block=""
    block+="# Linux <-> SHARC+ DDR split (config.mk LINUX_MEM) - consumed by the"$'\n'
    block+="# meta-custom-bsp linux-adi bbappend (sets the DT /memory node + mem=)."$'\n'
    block+="LINUX_MEM = \"$LINUX_MEM\""$'\n'
    block+="LINUX_MEM_BASE = \"$base_hex\""$'\n'
    block+="LINUX_MEM_SIZE = \"$size_hex\""$'\n'
    block+="LINUX_MEM_BASE_NODE = \"$base_node\""$'\n'

    local tmp; tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$end" ]; then printf '%s' "$block"; fi
        printf '%s\n' "$line"
    done < "$target" > "$tmp"
    cat "$tmp" > "$target"
    rm -f "$tmp"
    echo "[configure] Linux RAM -> mem=$LINUX_MEM  window=$base_hex+$size_hex  (SHARC+ gets ${sharc_mb} MB of ${DDR_SIZE:-512M})"
}

# Bake the board's resolver into the image: write BOARD_DNS into the managed
# local.conf block and pull in the meta-custom-bsp `board-dns` recipe (which drops
# an /etc/systemd/resolved.conf.d file setting systemd-resolved DNS=). Empty ->
# nothing injected, so the board keeps systemd's compiled-in FallbackDNS (1.1.1.1).
inject_board_dns() {
    local target="$1"
    [ -n "$BOARD_DNS" ] || return 0
    local end="# === END custom-apps overlay ==="
    local block=""
    block+="# Board DNS (config.mk BOARD_DNS) -> systemd-resolved drop-in, via the"$'\n'
    block+="# meta-custom-bsp board-dns recipe (pulled into the image just below)."$'\n'
    block+="BOARD_DNS = \"$BOARD_DNS\""$'\n'
    block+="IMAGE_INSTALL:append = \" board-dns\""$'\n'
    local tmp; tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$end" ]; then printf '%s' "$block"; fi
        printf '%s\n' "$line"
    done < "$target" > "$tmp"
    cat "$tmp" > "$target"
    rm -f "$tmp"
    echo "[configure] board DNS -> $BOARD_DNS  (+ board-dns into IMAGE_INSTALL)"
}

apply_overlay "$BUILD_DIR/conf/local.conf"    "$OVERLAYS_DIR/local.conf.fragment"
inject_revisions "$BUILD_DIR/conf/local.conf"
inject_linux_mem "$BUILD_DIR/conf/local.conf"
inject_board_dns "$BUILD_DIR/conf/local.conf"
apply_overlay "$BUILD_DIR/conf/bblayers.conf" "$OVERLAYS_DIR/bblayers.conf.fragment"

echo "[configure] Done."
echo "[configure]   build dir : $BUILD_DIR"
echo "[configure]   machine   : $MACHINE"
echo "[configure]   distro    : $DISTRO"
echo "[configure]   som/crr   : ${SOM_REV:-<BSP default>} / ${CRR_REV:-<BSP default>}"
echo "[configure]   linux RAM : ${LINUX_MEM:-<BSP default>} (of ${DDR_SIZE:-512M} DDR)"
echo "[configure]   board DNS : ${BOARD_DNS:-<systemd fallback 1.1.1.1>}"
echo "[configure]   layer dir : $LAYER_DIR"

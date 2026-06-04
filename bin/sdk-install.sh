#!/usr/bin/env bash
#
# sdk-install.sh — install the ADI SDK produced by `bitbake <image> -c populate_sdk`
# into a chosen directory, so `make openocd` (and cross-app builds) can use it.
#
# Yocto's populate_sdk task drops a self-extracting installer in the deploy dir:
#     tmp/deploy/sdk/<distro>-glibc-x86_64-<image>-<machine>-toolchain-<ver>.sh
# This script finds the newest such installer and runs it non-interactively:
#     [SUDO] <installer> -y -d <install-dir>
# (-y = accept defaults, -d = target dir; the installer relocates the toolchain)
# then checks that OpenOCD landed where the openocd target expects it.
#
# Installing under /opt needs root -> pass --sudo sudo (config.mk SDK_SUDO=sudo)
# or choose a user-writable --install-dir.
#
# PORTABILITY: Linux. Run AFTER `bitbake <image> -c populate_sdk` (make sdk does
# both).

set -euo pipefail

DEPLOY_SDK_DIR=""
INSTALL_DIR=""
OPENOCD_BIN=""
SUDO_PREFIX=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy-sdk-dir) DEPLOY_SDK_DIR="$2"; shift 2 ;;
        --install-dir)    INSTALL_DIR="$2";    shift 2 ;;
        --openocd-bin)    OPENOCD_BIN="$2";    shift 2 ;;
        --sudo)           SUDO_PREFIX="$2";    shift 2 ;;
        *) echo "sdk-install.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -n "$DEPLOY_SDK_DIR" ] || { echo "sdk-install.sh: --deploy-sdk-dir required" >&2; exit 1; }
[ -n "$INSTALL_DIR" ]    || { echo "sdk-install.sh: --install-dir required"    >&2; exit 1; }

if [ ! -d "$DEPLOY_SDK_DIR" ]; then
    echo "[sdk] ERROR: SDK deploy dir not found: $DEPLOY_SDK_DIR" >&2
    echo "[sdk]        run 'bitbake <image> -c populate_sdk' first (make sdk does this)." >&2
    exit 1
fi

# Newest installer (.sh) in the deploy dir. populate_sdk also drops .manifest /
# .testdata.json siblings; only the .sh is the installer.
mapfile -t installers < <(ls -1t "$DEPLOY_SDK_DIR"/*.sh 2>/dev/null || true)
if [ "${#installers[@]}" -eq 0 ]; then
    echo "[sdk] ERROR: no *.sh SDK installer in $DEPLOY_SDK_DIR" >&2
    echo "[sdk]        did 'bitbake <image> -c populate_sdk' complete?" >&2
    exit 1
fi
INSTALLER="${installers[0]}"
if [ "${#installers[@]}" -gt 1 ]; then
    echo "[sdk] note: ${#installers[@]} installers present; using the newest."
fi
echo "[sdk] installer: $INSTALLER"
chmod +x "$INSTALLER" 2>/dev/null || true

# Pre-flight: can we write INSTALL_DIR? Walk to the nearest existing ancestor and
# test it, so we fail clearly instead of deep inside the installer.
probe="$INSTALL_DIR"
while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do probe="$(dirname "$probe")"; done
if [ -z "$SUDO_PREFIX" ] && [ ! -w "$probe" ]; then
    echo "[sdk] ERROR: $INSTALL_DIR is not writable (nearest existing: $probe)" >&2
    echo "[sdk]        and no --sudo set. Re-run with SDK_SUDO=sudo, or choose a" >&2
    echo "[sdk]        user-writable SDK_INSTALL_DIR." >&2
    exit 1
fi

echo "[sdk] Installing into $INSTALL_DIR ${SUDO_PREFIX:+(via $SUDO_PREFIX) }..."
# SUDO_PREFIX intentionally unquoted so "sudo" / "sudo -E" word-splits.
if ! ${SUDO_PREFIX} "$INSTALLER" -y -d "$INSTALL_DIR"; then
    echo "[sdk] ERROR: SDK installer failed (see output above)." >&2
    exit 1
fi

echo ""
if [ -n "$OPENOCD_BIN" ] && [ -x "$OPENOCD_BIN" ]; then
    echo "[sdk] OK: OpenOCD present -> $OPENOCD_BIN"
    echo "[sdk]     'make openocd' is ready to use."
elif [ -n "$OPENOCD_BIN" ]; then
    echo "[sdk] WARNING: SDK installed, but OpenOCD is not at the expected path:" >&2
    echo "[sdk]          $OPENOCD_BIN" >&2
    echo "[sdk]          The SDK for this image may not include nativesdk-openocd, or" >&2
    echo "[sdk]          OPENOCD_BIN/OPENOCD_SDK_ROOT don't match SDK_INSTALL_DIR." >&2
    echo "[sdk]          Inspect: $INSTALL_DIR" >&2
else
    echo "[sdk] SDK installed into $INSTALL_DIR"
fi
echo "[sdk] Done."

#!/usr/bin/env bash
#
# nfs-server.sh — set up / inspect an NFS-root export for SC598 development.
#
# Booting the board against a rootfs that lives on THIS host over NFS beats
# reflashing for every change: edit files under NFS_DIR, reboot the board, the
# change is live. The board's ADI initramfs greps `nfsroot=` from the kernel
# cmdline, mounts it, and switch_root's into it (NO `root=`). Pairs with the
# JTAG + TFTP fitImage boot.
#
# SUBCOMMANDS
#   setup    Install nfs-kernel-server, extract the rootfs tarball into --nfs-dir
#            (preserving owners/perms/device nodes), and export it. NEEDS ROOT
#            (run via sudo / NFS_SUDO). Idempotent: skips extraction if --nfs-dir
#            already holds a rootfs unless --force (so live edits survive a re-run).
#   status   Show NFS server + export state and print the exact U-Boot bootargs
#            to boot this NFS root. No root needed.
#
# OPTIONS (long flags; the Makefile passes them from config.mk):
#   --nfs-dir DIR     export + extract dir              (required for setup)
#   --rootfs-tar FILE rootfs tarball (else derived from --deploy-dir/-image/-machine)
#   --deploy-dir DIR  bitbake deploy images dir (to derive the tarball)
#   --image NAME      image recipe name      (to derive the tarball)
#   --machine NAME    machine name           (to derive the tarball)
#   --allow SPEC      /etc/exports client spec; default <host-ip>/24
#   --host-ip IP      this host's IP; default auto-detected (primary global IPv4)
#   --board-ip IP     board's static IP, for the ip= bootarg / status
#   --netmask MASK    netmask, for the ip= bootarg / status
#   --gateway IP      default gateway, for the ip= bootarg / status (optional)
#   --hostname NAME   hostname, for the ip= bootarg / status
#   --nfs-vers N      NFS version for the mount (default 3)
#   --force           setup: wipe + re-extract even if --nfs-dir is populated
#
# PORTABILITY: Linux + Debian/Ubuntu nfs-kernel-server. Other distros: install an
# NFS server yourself; `setup` then reuses it (it only auto-installs via apt-get).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUB="${1:-}"; shift || true

NFS_DIR=""; ROOTFS_TAR=""; DEPLOY_DIR=""; IMAGE=""; MACHINE=""
ALLOW=""; HOST_IP=""; BOARD_IP=""; NFS_VERS="3"; FORCE=""; NETMASK=""; HOSTNAME=""; GATEWAY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nfs-dir)     NFS_DIR="$2";    shift 2 ;;
        --rootfs-tar)  ROOTFS_TAR="$2"; shift 2 ;;
        --deploy-dir)  DEPLOY_DIR="$2"; shift 2 ;;
        --image)       IMAGE="$2";      shift 2 ;;
        --machine)     MACHINE="$2";    shift 2 ;;
        --allow)       ALLOW="$2";      shift 2 ;;
        --host-ip)     HOST_IP="$2";    shift 2 ;;
        --board-ip)    BOARD_IP="$2";   shift 2 ;;
        --netmask)     NETMASK="$2";    shift 2 ;;
        --hostname)    HOSTNAME="$2";   shift 2 ;;
        --gateway)     GATEWAY="$2";    shift 2 ;;
        --nfs-vers)    NFS_VERS="$2";   shift 2 ;;
        --force)       FORCE=1;         shift ;;
        *) echo "nfs-server.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

log(){ echo "[nfs] $*"; }
die(){ echo "[nfs] ERROR: $*" >&2; exit 1; }

# Primary global IPv4 of this host (the address the board talks to).
detect_host_ip(){ ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{sub(/\/.*/,"",$4);print $4}'; }
# a.b.c.d -> a.b.c.0/24
slash24(){ printf '%s\n' "$1" | awk -F. 'NF==4{print $1"."$2"."$3".0/24"}'; }
# explicit --rootfs-tar, else <deploy>/<image>-<machine>.rootfs.tar.xz
resolve_tar(){
    if [ -n "$ROOTFS_TAR" ]; then printf '%s\n' "$ROOTFS_TAR"; return; fi
    [ -n "$DEPLOY_DIR" ] && [ -n "$IMAGE" ] && [ -n "$MACHINE" ] || return 0
    printf '%s\n' "$DEPLOY_DIR/$IMAGE-$MACHINE.rootfs.tar.xz"
}
# Debian uses nfs-kernel-server; some distros call it nfs-server.
nfs_unit(){
    local u
    for u in nfs-kernel-server nfs-server; do
        systemctl list-unit-files "$u.service" >/dev/null 2>&1 && { echo "$u"; return; }
    done
    echo "nfs-kernel-server"
}
[ -n "$HOST_IP" ] || HOST_IP="$(detect_host_ip)"

# The bootargs + tftp/bootm lines are built by the shared emitter so that
# `make nfs-status` and `make boot` can never drift apart. Export what it reads
# (an empty NETMASK/HOSTNAME falls back to the emitter's defaults), force the
# NFS bootargs shape, then source it. bootcmds_print_uboot reads NFS_DIR live.
export BOARD_IP HOST_IP NFS_DIR NFS_VERS
export BOARD_NETMASK="$NETMASK" BOARD_HOSTNAME="$HOSTNAME" BOARD_GATEWAY="$GATEWAY" BOOT_METHOD=nfs
# shellcheck source=bin/lib/bootcmds.sh
source "$SCRIPT_DIR/lib/bootcmds.sh"

case "$SUB" in
  setup)
    [ -n "$NFS_DIR" ] || die "--nfs-dir is required (set NFS_DIR in config.mk)"
    [ "$(id -u)" -eq 0 ] || die "setup needs root — use 'make nfs-setup' (NFS_SUDO=sudo) or 'sudo $0 setup ...'"
    if ! command -v exportfs >/dev/null 2>&1; then
        log "installing nfs-kernel-server ..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq && apt-get install -y nfs-kernel-server
    fi
    TAR="$(resolve_tar)"
    [ -n "$TAR" ] || die "cannot resolve rootfs tarball — pass --rootfs-tar or --deploy-dir/--image/--machine"
    [ -f "$TAR" ] || die "rootfs tarball not found: $TAR  (run 'make image' first)"
    mkdir -p "$NFS_DIR"
    if [ -e "$NFS_DIR/sbin/init" ] && [ -z "$FORCE" ]; then
        log "rootfs already present at $NFS_DIR — skipping extract (--force to redo)"
    else
        [ -n "$FORCE" ] && { log "force: wiping $NFS_DIR"; rm -rf -- "${NFS_DIR:?}/"* "${NFS_DIR:?}/."[!.]* 2>/dev/null || true; }
        log "extracting $(basename "$TAR") -> $NFS_DIR"
        tar -xpf "$TAR" -C "$NFS_DIR" --numeric-owner --xattrs --xattrs-include='*' 2>/dev/null \
            || tar -xpf "$TAR" -C "$NFS_DIR" --numeric-owner
    fi
    [ -n "$ALLOW" ] || ALLOW="$(slash24 "${HOST_IP:-}")"
    [ -n "$ALLOW" ] || die "could not derive --allow (host IP unknown); pass --allow CIDR"
    EXPORT_OPTS="rw,no_root_squash,no_subtree_check,async,insecure"
    touch /etc/exports
    if grep -qE "^${NFS_DIR}[[:space:]]" /etc/exports; then
        log "replacing existing /etc/exports entry for $NFS_DIR"
        sed -i "\#^${NFS_DIR}[[:space:]]#d" /etc/exports
    fi
    echo "${NFS_DIR} ${ALLOW}(${EXPORT_OPTS})" >> /etc/exports
    log "export: ${NFS_DIR} ${ALLOW}(${EXPORT_OPTS})"
    UNIT="$(nfs_unit)"
    systemctl enable --now rpcbind  >/dev/null 2>&1 || true
    systemctl enable --now "$UNIT"  >/dev/null 2>&1 || systemctl restart "$UNIT" >/dev/null 2>&1 || true
    exportfs -ra
    log "active exports:"; exportfs -v 2>/dev/null | sed 's/^/    /' || true
    echo
    log "DONE — boot the board with (NO root=):"
    bootcmds_print_uboot
    ;;
  status)
    UNIT="$(nfs_unit)"
    if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
        log "NFS server : RUNNING ($UNIT)"
    else
        log "NFS server : not running ($UNIT) — run 'make nfs-setup'"
    fi
    systemctl is-active --quiet rpcbind 2>/dev/null && log "rpcbind    : active" || log "rpcbind    : inactive"
    log "host IP    : ${HOST_IP:-<unknown — set HOST_IP>}"
    if command -v showmount >/dev/null 2>&1; then
        log "exports    :"
        showmount -e localhost 2>/dev/null | tail -n +2 | sed 's/^/    /' || true
    fi
    if [ -n "$NFS_DIR" ] && [ -e "$NFS_DIR/sbin/init" ]; then
        log "rootfs     : present at $NFS_DIR"
    else
        log "rootfs     : NOT extracted at ${NFS_DIR:-<NFS_DIR unset>} — run 'make nfs-setup'"
    fi
    if [ -n "$NFS_DIR" ] && showmount -e localhost 2>/dev/null | awk '{print $1}' | grep -qx "$NFS_DIR"; then
        log "export     : $NFS_DIR is exported  OK"
    elif [ -n "$NFS_DIR" ]; then
        log "export     : $NFS_DIR is NOT exported yet"
    fi
    echo
    log "U-Boot bootargs for this NFS root (no root=):"
    bootcmds_print_uboot
    [ -n "${BOARD_IP:-}" ] || log "note: set BOARD_IP in config.mk to fill in <board-ip>"
    ;;
  ""|-h|--help)
    echo "Usage: nfs-server.sh {setup|status} --nfs-dir DIR [--board-ip IP] [--gateway IP] [--host-ip IP] [--allow CIDR] [--nfs-vers N] [--force]"
    ;;
  *) die "unknown subcommand: '$SUB' (use: setup | status)";;
esac

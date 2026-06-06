#!/usr/bin/env bash
#
# host-setup.sh - install the host prerequisites for the ADSP-SC598 Yocto harness.
#
# Detects the distro from /etc/os-release and installs, via the right package
# manager, the Yocto (scarthgap) build-host packages PLUS the tools this harness
# uses (curl, PyYAML, device-tree-compiler, minicom, TFTP/NFS). Supported:
#
#   apt     Debian, Ubuntu
#   dnf     Fedora, RHEL, Rocky, AlmaLinux, CentOS Stream   (+ EPEL/CRB)
#   pacman  Arch, Manjaro
#   zypper  openSUSE, SLES
#
# BEST-EFFORT BY DESIGN: package names vary across distros/releases. Unknown
# names are pre-filtered out (so one bad name never aborts the install), and a
# verification step at the end reports any critical tool still missing - the
# real check is "did the build tools end up present", not "did every name match".
#
# Needs root to install; auto-uses sudo when not already root.
#
# USAGE:
#   make host-setup              install
#   make host-setup DRY_RUN=1    just print the detected distro + package plan

set -euo pipefail

DRYRUN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRYRUN=1; shift ;;
        *) echo "host-setup.sh: unknown arg: $1" >&2; exit 1 ;;
    esac
done

log(){ echo "[host-setup] $*"; }
die(){ echo "[host-setup] ERROR: $*" >&2; exit 1; }

# sudo prefix (empty when already root)
SUDO=""
if [ "$(id -u)" != 0 ]; then
    command -v sudo >/dev/null 2>&1 && SUDO="sudo" || die "not running as root and 'sudo' not found"
fi

# --- detect distro + package manager ----------------------------------------
ID=""; ID_LIKE=""; PRETTY_NAME=""
[ -r /etc/os-release ] && . /etc/os-release || true
PRETTY="${PRETTY_NAME:-${ID:-unknown}}"

pm=""
case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*)              pm=apt ;;
    *" fedora "*|*" rhel "*|*" centos "*)   pm=dnf ;;
    *" arch "*)                              pm=pacman ;;
    *" suse "*|*" opensuse "*|*" sles "*)    pm=zypper ;;
esac
if [ -z "$pm" ]; then     # fall back to whatever tool exists
    for c in apt-get dnf yum pacman zypper; do
        command -v "$c" >/dev/null 2>&1 && { pm="$c"; break; }
    done
    [ "$pm" = apt-get ] && pm=apt
    [ "$pm" = yum ] && pm=dnf
fi
[ -n "$pm" ] || die "no supported package manager (apt/dnf/pacman/zypper) found. Distro: $PRETTY"

# RHEL-family (needs EPEL + CRB/PowerTools for several -devel/perl packages)
EL=""
case "${ID:-}" in rocky|almalinux|rhel|centos) EL=1 ;; esac
case " ${ID_LIKE:-} " in *" rhel "*|*" centos "*) EL=1 ;; esac

log "Distro : $PRETTY"
log "Manager: $pm${EL:+   (RHEL-family: will enable EPEL + CRB/PowerTools)}"

# --- package lists per manager (Yocto build host + harness tools) ------------
case "$pm" in
  apt) PKGS=( gawk wget git diffstat unzip texinfo gcc build-essential chrpath socat cpio
              python3 python3-pip python3-pexpect xz-utils debianutils iputils-ping
              python3-git python3-jinja2 python3-subunit libegl1-mesa libsdl1.2-dev
              mesa-common-dev zstd liblz4-tool file locales libacl1
              curl python3-yaml device-tree-compiler minicom tftp-hpa tftpd-hpa nfs-kernel-server ) ;;
  dnf) PKGS=( gawk make wget tar bzip2 gzip python3 unzip perl patch diffutils diffstat git
              cpp gcc gcc-c++ glibc-devel texinfo chrpath ccache socat python3-pexpect findutils
              which file cpio python3-pip xz python3-GitPython python3-jinja2 python3-subunit
              perl-Data-Dumper perl-Text-ParseWords perl-Thread-Queue perl-bignum perl-FindBin
              perl-File-Compare perl-File-Copy SDL-devel rpcgen mesa-libGL-devel zstd lz4
              hostname glibc-langpack-en
              curl python3-pyyaml dtc minicom tftp tftp-server nfs-utils gh ) ;;
  pacman) PKGS=( base-devel git diffstat unzip texinfo python python-pip chrpath socat cpio
                 python-pexpect python-gitpython python-jinja rpcsvc-proto sdl2 mesa wget xz
                 zstd lz4 which inetutils tar
                 curl python-yaml dtc minicom tftp-hpa nfs-utils github-cli ) ;;
  zypper) PKGS=( gawk make wget tar bzip2 gzip python3 unzip perl patch diffutils diffstat git
                 gcc gcc-c++ glibc-devel texinfo chrpath socat python3-pexpect findutils which
                 file cpio python3-pip xz python3-GitPython python3-jinja2 python3-subunit
                 python3-curses rpm-build perl-bignum zstd lz4 libacl-devel
                 curl python3-PyYAML dtc minicom tftp nfs-kernel-server gh ) ;;
esac

if [ -n "$DRYRUN" ]; then
    log "DRY RUN - would install ${#PKGS[@]} packages via $pm:"
    printf '%s ' "${PKGS[@]}" | fmt -w 74 | sed 's/^/    /'
    [ -n "$EL" ] && log "DRY RUN - would also enable EPEL + CRB/PowerTools first."
    exit 0
fi

# --- refresh metadata + enable extra repos -----------------------------------
case "$pm" in
    apt)    log "apt-get update ...";    $SUDO apt-get update -qq || true ;;
    dnf)    if [ -n "$EL" ]; then
                log "enabling EPEL + CRB/PowerTools ..."
                $SUDO dnf install -y epel-release || true
                $SUDO dnf config-manager --set-enabled crb        >/dev/null 2>&1 \
                  || $SUDO dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
            fi
            log "dnf makecache ...";     $SUDO dnf -q makecache || true ;;
    pacman) log "pacman -Sy ...";        $SUDO pacman -Sy --noconfirm || true ;;
    zypper) log "zypper refresh ...";    $SUDO zypper --non-interactive refresh || true ;;
esac

# pkg_exists <name> : succeed if the package is installable on this system
pkg_exists() {
    case "$pm" in
        apt)    apt-cache show "$1"   >/dev/null 2>&1 ;;
        dnf)    dnf -q info "$1"      >/dev/null 2>&1 ;;
        pacman) pacman -Si "$1" >/dev/null 2>&1 || pacman -Sg "$1" >/dev/null 2>&1 ;;
        zypper) zypper -q search -x -t package "$1" >/dev/null 2>&1 ;;
    esac
}

# pre-filter to installable names so one unknown name can't abort the batch
log "resolving package names ..."
avail=(); skip=()
for p in "${PKGS[@]}"; do
    if pkg_exists "$p"; then avail+=("$p"); else skip+=("$p"); fi
done
[ "${#skip[@]}" -gt 0 ] && log "not available on this distro (skipped): ${skip[*]}"
[ "${#avail[@]}" -gt 0 ] || die "no installable packages resolved - is the package manager metadata reachable?"

log "installing ${#avail[@]} packages via $pm ..."
case "$pm" in
    apt)    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${avail[@]}" || true ;;
    dnf)    $SUDO dnf install -y --skip-broken "${avail[@]}" || true ;;
    pacman) $SUDO pacman -S --needed --noconfirm "${avail[@]}" || true ;;
    zypper) $SUDO zypper --non-interactive install --no-recommends "${avail[@]}" || true ;;
esac

# --- verify the critical build tools actually ended up present ---------------
log "verifying critical tools ..."
miss=()
for t in gawk wget git diffstat unzip gcc g++ make chrpath socat cpio python3 xz zstd file bzip2 curl; do
    command -v "$t" >/dev/null 2>&1 || miss+=("$t")
done
python3 -c 'import yaml' 2>/dev/null || miss+=("python3 PyYAML (import yaml)")
if [ "${#miss[@]}" -eq 0 ]; then
    log "OK - all critical build tools are present."
else
    log "STILL MISSING - install these by hand: ${miss[*]}"
fi

# --- manual follow-ups -------------------------------------------------------
echo
log "Manual follow-ups (not done automatically):"
echo "  * git identity (repo/bitbake need it):"
echo "      git config --global user.name 'You' ; git config --global user.email you@host"
echo "  * serial console (make terminal): join 'dialout', then log out/in:"
echo "      $SUDO usermod -aG dialout \$(id -un)"
echo "  * GitHub CLI (make publish): 'gh' is in the repos on Fedora/Arch/openSUSE;"
echo "    on Debian/Ubuntu install it from https://cli.github.com (not in default repos)."
echo "  * net-boot servers: 'make tftp-ensure' and 'make nfs-setup' install/start those."
case "$pm" in apt) echo "  * locales: $SUDO sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && $SUDO locale-gen" ;; esac
echo
log "Done. (Preview anytime with: make host-setup DRY_RUN=1)"

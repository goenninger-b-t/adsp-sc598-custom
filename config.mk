# ============================================================================
#  config.mk - Per-project build settings for the ADSP-SC598 Yocto BSP
# ============================================================================
#
# This file is included by the top-level Makefile and defines all user-tunable
# settings. Anything you want to change project-wide (machine, image, GitHub
# release target, ...) belongs here.
#
# Edit the values below to set your project defaults. Variables can still be
# overridden on a per-invocation basis from the cmdline (see below).
#
# ----------------------------------------------------------------------------
#  Variable precedence
# ----------------------------------------------------------------------------
#
# Each variable uses conditional assignment (`?=`), so the precedence is:
#
#   1. Command-line argument  (highest)   make IMAGE=foo
#   2. Exported environment variable      export IMAGE=foo; make
#   3. Value from this file   (lowest)    IMAGE ?= foo
#
# Set your default below; use the cmdline for one-off builds.
#
# ----------------------------------------------------------------------------
#  Quick reference - common usage
# ----------------------------------------------------------------------------
#
#   # First-time bootstrap (uses defaults from this file):
#   make init           # download repo + repo init the ADI BSP manifest
#   make fetch          # repo sync the BSP sources (auto-runs init first)
#   make image          # bitbake the default image
#   make sdcard         # decompress wic.gz to output/sdcard.img
#   make flash DEV=/dev/sdX
#
#   # Build a different machine for one invocation:
#   make image MACHINE=adsp-sc594-som-ezkit
#
#   # Build a stock ADI image instead of the auto-generated custom one:
#   make image IMAGE=adsp-sc5xx-minimal-mmc
#
#   # Publish the built image as a GitHub release:
#   make publish GH_REPO=youruser/yourrepo GH_VERSION=1.0.0
#
# ============================================================================


# ============================================================================
#  Source fetch / `repo` bootstrap  (`make init`, `make fetch`)
# ============================================================================
#
# The ADI BSP is not a single git repo; it is dozens of repositories stitched
# together by Google's `repo` tool against a manifest published by Analog
# Devices. Bootstrapping is therefore two steps:
#
#   make init    Download the `repo` launcher (REPO_TOOL_URL) to src/bin/repo,
#                then `repo init` it against the ADI manifest
#                (REPO_MANIFEST_URL / _BRANCH / _FILE). Creates src/.repo/.
#   make fetch   `repo sync` - actually clone/update the BSP sources. If
#                src/.repo is absent it runs `make init` for you first.
#
# IMPORTANT - these come from two DIFFERENT places, do not confuse them:
#
#   * The `repo` LAUNCHER binary is Google's tool, hosted on Google Cloud
#     Storage - NOT on analog.com. ADI's own setup instructions tell you to
#     curl it from exactly that Google URL. -> REPO_TOOL_URL
#
#   * What genuinely comes "from Analog Devices" is the MANIFEST git repo in
#     their GitHub org (analogdevicesinc). `repo init -u` points here, and it
#     in turn names every component repo to sync. -> REPO_MANIFEST_URL
#
# You normally only ever touch REPO_MANIFEST_BRANCH / _FILE (to pick a BSP
# release); the two URLs rarely change.

# ------- REPO_TOOL_URL ------------------------------------------------------
# URL of the `repo` launcher script (Google's git-repo tool). `make init`
# curls this to src/bin/repo and makes it executable.
#
# The canonical, ADI-documented source is Google Cloud Storage. The fetch
# uses `curl -fSL`, so an http URL that redirects to https is fine. Override
# this only if you mirror `repo` behind a corporate proxy/firewall.
#
# Examples:
#   REPO_TOOL_URL ?= https://commondatastorage.googleapis.com/git-repo-downloads/repo
#   REPO_TOOL_URL ?= https://storage.googleapis.com/git-repo-downloads/repo
#   make init REPO_TOOL_URL=https://mirror.corp.example/tools/repo
REPO_TOOL_URL        ?= https://commondatastorage.googleapis.com/git-repo-downloads/repo


# ------- REPO_MANIFEST_URL --------------------------------------------------
# Git URL of the Analog Devices repo manifest - the actual ADI-hosted piece
# of the bootstrap. Passed to `repo init -u`. Default is the upstream ADI
# manifest on GitHub; point it at a fork if you maintain your own.
#
# Examples:
#   REPO_MANIFEST_URL ?= https://github.com/analogdevicesinc/lnxdsp-repo-manifest.git
#   make init REPO_MANIFEST_URL=git@github.com:youruser/lnxdsp-repo-manifest.git
REPO_MANIFEST_URL    ?= https://github.com/analogdevicesinc/lnxdsp-repo-manifest.git


# ------- REPO_MANIFEST_BRANCH -----------------------------------------------
# Manifest branch passed to `repo init -b`. Selects the BSP release line.
#
# Examples:
#   REPO_MANIFEST_BRANCH ?= main
#   make init REPO_MANIFEST_BRANCH=yocto-4.0
REPO_MANIFEST_BRANCH ?= main


# ------- REPO_MANIFEST_FILE -------------------------------------------------
# Manifest XML file inside the manifest repo, passed to `repo init -m`. Pins
# the exact set of component revisions for a specific ADI BSP release.
#
# Examples:
#   REPO_MANIFEST_FILE ?= release-5.0.1.xml
#   make init REPO_MANIFEST_FILE=release-5.0.0.xml
REPO_MANIFEST_FILE   ?= release-5.0.1.xml


# ============================================================================
#  Build settings
# ============================================================================

# ------- BUILDDIR -----------------------------------------------------------
# Name of the bitbake build subdirectory under src/.
# Default "build" -> the build tree lives at src/build/.
#
# A previously-sourced `oe-init-build-env` exports BUILDDIR as an absolute
# path; the top-level Makefile strips it back to the basename, so you do not
# need to worry about that leakage.
#
# Examples:
#   make image                    # uses src/build/
#   make image BUILDDIR=mybuild   # uses src/mybuild/
BUILDDIR    ?= build


# ------- MACHINE ------------------------------------------------------------
# The Yocto MACHINE target. Determines which BSP code is used, which u-boot
# defconfig is built, which kernel device tree is selected, ...
#
# Supported values (from sources/meta-adi/meta-adi-adsp-sc5xx/conf/machine/):
#
#   adsp-sc573-ezkit
#   adsp-sc589-mini
#   adsp-sc594-som-ezkit
#   adsp-sc594-som-ezlite
#   adsp-sc598-som-ezkit       <-- default; SC598 SOM on the EZ-KIT carrier
#   adsp-sc598-som-ezlite
#
# Examples:
#   MACHINE ?= adsp-sc598-som-ezkit
#   make image MACHINE=adsp-sc594-som-ezkit
MACHINE     ?= adsp-sc598-som-ezkit


# ------- DISTRO -------------------------------------------------------------
# The Yocto DISTRO policy. Selects toolchain settings, default
# DISTRO_FEATURES, version pinning, init system, ...
#
# Supported values (from sources/meta-adi*/conf/distro/):
#
#   adi-distro-glibc      <-- default; standard glibc-based system w/ systemd
#   adi-distro-musl       smaller, musl libc - has caveats (some packages
#                         do not build under musl)
#
# Examples:
#   DISTRO ?= adi-distro-glibc
DISTRO      ?= adi-distro-glibc


# ------- IMAGE --------------------------------------------------------------
# The bitbake image recipe to build.
#
# The generator (`make apps`) automatically creates `adi-sc5xx-custom.bb` in
# src/layers/meta-custom-apps/recipes-core/images/. This recipe inherits
# adsp-sc5xx-minimal-mmc (SD-card capable) and pulls in every app defined
# under src/apps/ via packagegroup-custom-apps. That is the default below.
#
# Other available images from the stock ADI BSP:
#
#   adsp-sc5xx-full          kitchen-sink: utilities + sound stack + ptest
#   adsp-sc5xx-minimal       minimal rootfs, no SD-card wic
#   adsp-sc5xx-minimal-mmc   minimal + SD-card wic layout (basis for custom)
#   adsp-sc5xx-tiny          absolute smallest rootfs
#   adsp-sc5xx-ramdisk       initramfs-only (used internally for FIT)
#
# Examples:
#   make image                                  # adi-sc5xx-custom (default)
#   make image IMAGE=adsp-sc5xx-minimal-mmc     # stock ADI minimal+SD image
IMAGE       ?= adi-sc5xx-custom


# ------- SOM_REV / CRR_REV --------------------------------------------------
# Hardware revision selectors written into conf/local.conf by `make configure`
# (ADI getting-started: "Check and select the appropriate revision"):
#     SOM_REV = "<value>"
#     CRR_REV = "<value>"
# They pin the build to your specific SoM and carrier-board revision. Leave them
# EMPTY to use the BSP default, which ADI documents as valid for SOM Rev A/B/C/D
# with an EZ-Kit Carrier rev D - set them only if your hardware differs. (Empty
# values are omitted from local.conf; do NOT set the literal "<...>" placeholder,
# it is not a valid revision.) Identify your revisions from the board, per ADI's
# "Guide to identify SOM and EZKit Carrier revision numbers".
#
# Examples:
#   SOM_REV ?=
#   CRR_REV ?=
#   make image SOM_REV=D CRR_REV=D
SOM_REV     ?=
CRR_REV     ?=


# ------- LINUX_MEM  (Linux <-> SHARC+ DDR split) ----------------------------
# How much of the SoC's DDR is assigned to Linux. The ADSP-SC598 shares ONE DDR
# between the Cortex-A55 (Linux) and the SHARC+ cores. LINUX_MEM is the single
# knob: Linux gets the TOP LINUX_MEM of physical DDR and the SHARC+ cores get the
# REST (DDR_SIZE - LINUX_MEM) at the bottom. There is no separate SHARC setting -
# the reserve is simply whatever DDR Linux does not take.
#
# `make configure` validates LINUX_MEM and writes the resulting Linux DDR window
# into the build (conf/local.conf); meta-custom-bsp bbappends then set U-Boot's
# CFG_SYS_SDRAM_BASE/SIZE AND the kernel device-tree /memory node + mem= bootarg
# from it. (U-Boot's bootm rewrites the kernel /memory node from CFG_SYS_SDRAM_*,
# so both are set and kept in agreement.) LINUX_MEM also feeds `make boot`
# (BOOT_MEM derives from it), so the JTAG/NFS boot and the built image agree.
#
# Valid range:  112M <= LINUX_MEM <= DDR_SIZE
#   - upper: it must fit physical DDR (DDR_SIZE).
#   - lower: the FIT image loads the kernel DTB at 0x99000000, which must sit
#     inside Linux's window, so Linux's base (DDR top - LINUX_MEM) must stay
#     <= 0x99000000, i.e. LINUX_MEM >= 112M.
#
# Layout at the 224M default (of 512M):
#   SHARC+ : 0x80000000 .. 0x92000000   (DDR_SIZE - LINUX_MEM = 288 MB)
#   Linux  : 0x92000000 .. 0xA0000000   (LINUX_MEM           = 224 MB)
#
# Examples:
#   LINUX_MEM ?= 224M            # default; leaves 288 MB for the SHARC+ cores
#   make image LINUX_MEM=384M    # Linux 384 MB, SHARC+ 128 MB
#   make image LINUX_MEM=512M    # all DDR to Linux (no SHARC+ DDR)
LINUX_MEM   ?= 224M

# ------- DDR_SIZE / DDR_BASE  (physical DDR on the SOM) ----------------------
# Total physical DDR size and base address - board facts. The ADSP-SC598 SOM
# Rev E has 512 MB at 0x80000000 (confirm live with `make board-info`, which
# probes the DMC controllers). LINUX_MEM is bounded by DDR_SIZE, and Linux's
# window is placed at the top of [DDR_BASE, DDR_BASE + DDR_SIZE).
#
# Examples:
#   DDR_SIZE ?= 512M
#   DDR_BASE ?= 0x80000000
DDR_SIZE    ?= 512M
DDR_BASE    ?= 0x80000000


# ----------------------------------------------------------------------------
#  TFTP staging  (`make tftp`)
# ----------------------------------------------------------------------------

# TFTP_DIR
#   Filesystem path of the directory served by your TFTP server. `make tftp`
#   copies the following boot artifacts into this directory:
#
#     fitImage                                       (signed bundle: kernel
#                                                     + dtb + ramdisk - the
#                                                     canonical ADI artifact,
#                                                     loadable with one
#                                                     tftpboot + bootm)
#     Image.gz                                       (kernel, for discrete
#                                                     boot)
#     <BOARD>.dtb                                    (device tree, e.g.
#                                                     sc598-som-ezkit.dtb)
#     adsp-sc5xx-ramdisk-<MACHINE>.rootfs.cpio.gz    (initial ramdisk)
#
#   plus a README.tftp-boot with example u-boot commands.
#
#   This directory MUST be writable by the user running make. If your TFTP
#   server's document root is owned by root, either:
#     - point TFTP_DIR at a user-writable subdir (then bind-mount / symlink
#       it under the real tftp root), or
#     - chown the tftp root to your user.
#
#   On Debian/Ubuntu with tftpd-hpa, the document root is typically
#   /srv/tftp/ (configured in /etc/default/tftpd-hpa).
#
#   `make publish` automatically also runs the TFTP staging if TFTP_DIR is
#   non-empty, so a single `make publish` provisions both the GitHub release
#   and the TFTP server.
#
#   Default is empty. Leave it that way if you do not net-boot the board;
#   `make publish` will then skip the TFTP step with a notice.
#
#   Related targets (work without TFTP_DIR, but use it to cross-check when set):
#     make tftp-status   - TFTP server running? listen addr:port, served dir, config
#     make tftp-ensure   - start an installed-but-stopped TFTP server (via sudo)
#     make tftp-test     - list served files + verify one downloads over TFTP
#                          (optional: TFTP_TEST_FILE=<name> TFTP_TEST_HOST=<ip>)
#
#   Examples:
#     TFTP_DIR ?= /srv/tftp/adsp-sc598
#     TFTP_DIR ?= /home/lab/tftp
#     make tftp TFTP_DIR=/tmp/sc598-boot
TFTP_DIR    ?=



# ============================================================================
#  NFS root  (`make nfs-setup`, `make nfs-status`)
# ============================================================================
#
# Boot the board against a rootfs that lives on THIS host over NFS - edit files,
# reboot, the change is live, no reflash. `make nfs-setup` extracts the built
# rootfs into NFS_DIR and exports it; the board's ADI initramfs greps `nfsroot=`
# from the kernel cmdline, mounts it, and switch_root's into it (NO `root=`).
# Pairs with the JTAG + TFTP fitImage boot. Typical flow:
#
#   make image                     # build the rootfs (...rootfs.tar.xz)
#   make nfs-setup                 # install nfsd, extract + export NFS_DIR (sudo)
#   make nfs-status                # exports live? + the exact u-boot bootargs
#   # then in U-Boot: paste the printed `setenv bootargs ...` + tftp + bootm
#
# `make nfs-setup` needs root (installs nfs-kernel-server, writes /etc/exports,
# extracts device nodes) and runs via NFS_SUDO.

# ------- NFS_DIR ------------------------------------------------------------
# Host directory the rootfs is extracted into AND exported over NFS. The board
# mounts <HOST_IP>:<NFS_DIR>. Re-running `make nfs-setup` preserves your live
# edits (extracts only if empty; `--force` re-extracts). Empty -> the nfs targets
# error and tell you to set it. Machine-specific; keep your value local.
#
# Examples:
#   NFS_DIR ?= /srv/nfs/sc598-rootfs
#   NFS_DIR ?= /home/lab/nfs/sc598
NFS_DIR     ?=

# ------- BOARD_IP -----------------------------------------------------------
# The board's static IP. SHARED by the NFS targets and `make boot`:
#   - `make boot` runs `setenv ipaddr <BOARD_IP>` at the U-Boot prompt, and
#   - it fills the client field of the kernel `ip=` bootarg that brings up the
#     interface before the NFS mount.
# Must be free on your subnet and on the same network as HOST_IP.
#
# Examples:
#   BOARD_IP ?= 192.168.2.50
BOARD_IP    ?=

# ------- HOST_IP ------------------------------------------------------------
# This host's IP on the board's network. SHARED: it is the TFTP `serverip`
# `make boot` sets in U-Boot AND the NFS server the board mounts from. Empty ->
# the scripts auto-detect the primary global IPv4; set it when several NICs make
# the wrong one get picked.
#
# Examples:
#   HOST_IP ?= 192.168.2.180
HOST_IP     ?=

# ------- BOARD_NETMASK / BOARD_GATEWAY / BOARD_HOSTNAME ---------------------
# The remaining kernel `ip=` fields (`ip=<client>:<server>:<gw>:<netmask>:
# <hostname>:<dev>:off`), shared by `make boot` and the bootargs `make nfs-status`
# prints. BOARD_GATEWAY is optional (empty -> the "::" the board boots with
# today). BOARD_HOSTNAME is the name the kernel assigns over the cmdline.
#
# Examples:
#   BOARD_NETMASK  ?= 255.255.255.0
#   BOARD_GATEWAY  ?= 192.168.2.1
#   BOARD_HOSTNAME ?= sc598
BOARD_NETMASK  ?= 255.255.255.0
BOARD_GATEWAY  ?=
BOARD_HOSTNAME ?= sc598

# ------- NFS_ALLOW ----------------------------------------------------------
# Client spec allowed to mount the export (the /etc/exports left-hand side).
# Empty -> derived as the /24 of HOST_IP (e.g. 192.168.2.0/24). Narrow it to a
# single host or a different CIDR to restrict access.
#
# Examples:
#   NFS_ALLOW ?= 192.168.2.0/24
#   NFS_ALLOW ?= 192.168.2.50          # only this board
NFS_ALLOW   ?=

# ------- NFS_VERS -----------------------------------------------------------
# NFS protocol version for the board's mount (the nfsroot= option in the printed
# bootargs). 3 is simplest for an embedded root (no v4 pseudo-fs); the kernel has
# CONFIG_NFS_V3=y. Use 4 only if you reconfigure the export accordingly.
#
# Examples:
#   NFS_VERS ?= 3
NFS_VERS    ?= 3

# ------- NFS_SUDO -----------------------------------------------------------
# Command prefix for the privileged half of `make nfs-setup` (apt install,
# /etc/exports, exportfs, device-node extraction). Defaults to `sudo`; set empty
# if you already run as root.
#
# Examples:
#   NFS_SUDO ?= sudo
#   make nfs-setup NFS_SUDO=
NFS_SUDO    ?= sudo


# ============================================================================
#  ADI SDK (cross-toolchain + host tools)  (`make sdk`)
# ============================================================================
#
# `make sdk` builds the ADI SDK (Yocto `populate_sdk`) for SDK_IMAGE and runs the
# resulting self-extracting installer to install it into SDK_INSTALL_DIR. The SDK
# provides the aarch64 cross-toolchain plus host tools - notably OpenOCD and GDB -
# that `make openocd` then uses. This mirrors the ADI getting-started guide's
# "Building the SDK" step.
#
#   make sdk                       # build + install to SDK_INSTALL_DIR
#   make openocd                   # uses the OpenOCD from that SDK
#
# The build step is heavy the first time; it is incremental thereafter.

# ------- SDK_VERSION --------------------------------------------------------
# Version component of the SDK install path. Should match your BSP release
# (cf. REPO_MANIFEST_FILE: release-5.0.1.xml -> 5.0.1). Feeds SDK_INSTALL_DIR.
#
# Examples:
#   SDK_VERSION ?= 5.0.1
SDK_VERSION        ?= 5.0.1

# ------- SDK_IMAGE ----------------------------------------------------------
# The image whose SDK is built: `bitbake $(SDK_IMAGE) -c populate_sdk`. Defaults
# to your project IMAGE so the SDK matches what you build; ADI's guide uses
# adsp-sc5xx-minimal-mmc. Any image whose SDK includes nativesdk-openocd works
# for the openocd target.
#
# Examples:
#   SDK_IMAGE ?= $(IMAGE)
#   make sdk SDK_IMAGE=adsp-sc5xx-minimal-mmc
SDK_IMAGE          ?= $(IMAGE)

# ------- SDK_INSTALL_DIR ----------------------------------------------------
# Where the SDK installer drops the toolchain + host tools. This is the
# configurable path shared with the openocd target (OPENOCD_SDK_ROOT derives
# from it). The ADI default /opt/<DISTRO>/<SDK_VERSION> needs root to write
# (-> set SDK_SUDO=sudo); point it at a user-writable dir to avoid sudo.
#
# Examples:
#   SDK_INSTALL_DIR ?= /opt/adi-distro-glibc/5.0.1
#   make sdk SDK_INSTALL_DIR=$(HOME)/sc598-sdk        # user-writable, no sudo
SDK_INSTALL_DIR    ?= /opt/$(DISTRO)/$(SDK_VERSION)

# ------- SDK_SUDO -----------------------------------------------------------
# Command prefix to run the SDK installer when SDK_INSTALL_DIR is not writable
# by your user (e.g. the default under /opt). Empty by default.
#
# Examples:
#   SDK_SUDO ?=
#   make sdk SDK_SUDO=sudo
SDK_SUDO           ?=


# ============================================================================
#  JTAG / OpenOCD debugging  (`make openocd`)
# ============================================================================
#
# `make openocd` launches the ADI fork of OpenOCD against the SC598 over a JTAG
# emulator (ICE-1000 / ICE-2000), reproducing the "Terminal2: OpenOCD" step of
# the ADI getting-started guide (Linux for ADSP-SC5xx Processors 5.0.1):
#
#     $sdk_usr/bin/openocd \
#         -f $sdk_usr/share/openocd/scripts/interface/ice1000.cfg \
#         -f $sdk_usr/share/openocd/scripts/target/adspsc59x_a55.cfg
#
# OpenOCD then serves a GDB remote on OPENOCD_GDB_PORT (3333). In another window
# you connect the SDK's aarch64 GDB to :3333 to load U-Boot SPL/proper into RAM.
#
# WHERE OPENOCD COMES FROM
#   OpenOCD and its .cfg scripts ship in the ADI *SDK*, not the target image.
#   Build + install it once with `make sdk` (see the SDK section above). The
#   OPENOCD_* paths below derive from SDK_INSTALL_DIR. If you built OpenOCD
#   yourself, override OPENOCD_BIN / OPENOCD_SCRIPTS directly.
#
# HARDWARE
#   Board DEBUG port -> ICE-1000/ICE-2000 -> host USB; board USB/UART -> host
#   (serial console); BMODE in the JTAG/bootrom position while flashing U-Boot.
#
# USB PERMISSIONS
#   The ICE is a libusb device. Without udev rules granting your user access,
#   OpenOCD must run as root -> set OPENOCD_SUDO=sudo (or install ADI's rules).

# ------- OPENOCD_SDK_ROOT ---------------------------------------------------
# The ADI SDK host sysroot ".../usr" that contains bin/openocd and
# share/openocd/scripts. Derived from SDK_INSTALL_DIR (where `make sdk` puts the
# SDK). Override wholesale if your SDK lives elsewhere or was built for a
# non-x86_64 host.
#
# Examples:
#   OPENOCD_SDK_ROOT ?= /opt/adi-distro-glibc/5.0.1/sysroots/x86_64-adi_glibc_sdk-linux/usr
OPENOCD_SDK_ROOT   ?= $(SDK_INSTALL_DIR)/sysroots/x86_64-adi_glibc_sdk-linux/usr

# ------- OPENOCD_BIN / OPENOCD_SCRIPTS --------------------------------------
# The openocd binary and the directory holding its interface/ and target/ .cfg
# trees. Derived from OPENOCD_SDK_ROOT; override if you built ADI's OpenOCD from
# source (then point at <srcdir>/src/openocd and <srcdir>/tcl).
#
# Examples:
#   OPENOCD_BIN     ?= /opt/.../usr/bin/openocd
#   OPENOCD_SCRIPTS ?= /home/me/lnxdsp-openocd/tcl
OPENOCD_BIN        ?= $(OPENOCD_SDK_ROOT)/bin/openocd
OPENOCD_SCRIPTS    ?= $(OPENOCD_SDK_ROOT)/share/openocd/scripts

# ------- OPENOCD_ICE --------------------------------------------------------
# Which ADI JTAG emulator you have -> selects interface/<ICE>.cfg.
#   ice1000   5 MHz JTAG/SWD
#   ice2000   up to 46 MHz JTAG/SWD
#
# Examples:
#   OPENOCD_ICE ?= ice1000
#   make openocd OPENOCD_ICE=ice2000
OPENOCD_ICE        ?= ice1000

# ------- OPENOCD_TARGET -----------------------------------------------------
# OpenOCD target config under $(OPENOCD_SCRIPTS)/target/. The SC598 Cortex-A55
# (the core you debug to bring up U-Boot/Linux) is adspsc59x_a55.cfg.
#
# Examples:
#   OPENOCD_TARGET ?= adspsc59x_a55.cfg
OPENOCD_TARGET     ?= adspsc59x_a55.cfg

# ------- OPENOCD_GDB_PORT ---------------------------------------------------
# TCP port OpenOCD serves the GDB remote on (connect via
# `target extended-remote :<port>`). ADI's guide uses the OpenOCD default 3333.
#
# Examples:
#   OPENOCD_GDB_PORT ?= 3333
OPENOCD_GDB_PORT   ?= 3333

# ------- OPENOCD_SUDO -------------------------------------------------------
# Command prefix to elevate OpenOCD for raw USB access to the ICE. Defaults to
# `sudo` because the ICE / on-board FTDI debug device is root-owned out of the
# box, so OpenOCD otherwise aborts with libusb LIBUSB_ERROR_ACCESS ("cannot
# connect to ICE-1000 emulator"). For least privilege, install a udev rule for
# the adapter (see README "Troubleshooting") and set this back to empty.
#
# Examples:
#   OPENOCD_SUDO ?= sudo
#   make openocd OPENOCD_SUDO=            # after installing a udev rule
OPENOCD_SUDO       ?= sudo

# ------- OPENOCD_EXTRA_ARGS -------------------------------------------------
# Extra arguments appended verbatim to the openocd command line (power users):
# additional `-f file` configs or `-c "command"` TCL commands.
#
# Examples:
#   OPENOCD_EXTRA_ARGS ?=
#   make openocd OPENOCD_EXTRA_ARGS='-c "adapter speed 5000"'
OPENOCD_EXTRA_ARGS ?=


# ------- GDB_BIN ------------------------------------------------------------
# The SDK's aarch64 cross-GDB that `make gdb` runs to attach to OpenOCD.
# Auto-resolved from the installed SDK (the glibc build sorts first); override
# if it can't be found or you want the musl variant.
#
# Examples:
#   GDB_BIN ?= $(OPENOCD_SDK_ROOT)/bin/aarch64-adi_glibc-linux/aarch64-adi_glibc-linux-gdb
GDB_BIN            ?= $(firstword $(wildcard $(OPENOCD_SDK_ROOT)/bin/aarch64-*/aarch64-*-gdb $(OPENOCD_SDK_ROOT)/bin/aarch64-*-gdb))

# ------- GDB_ELF ------------------------------------------------------------
# Optional ELF (with symbols) for `make gdb` to load — typically the U-Boot SPL
# or proper image, so you can `load` it into RAM over JTAG. Empty -> `make gdb`
# auto-loads u-boot-spl-<board>.elf from the deploy dir if present, else connects
# with no symbol file.
#
# Examples:
#   GDB_ELF ?=
#   make gdb GDB_ELF=src/build/tmp/deploy/images/$(MACHINE)/u-boot-proper-sc598-som-ezkit.elf
GDB_ELF            ?=

# ------- GDB_HOST -----------------------------------------------------------
# Host running OpenOCD. Empty -> localhost (the OpenOCD that `make openocd`
# started on this machine). Set when OpenOCD runs on another host.
#
# Examples:
#   GDB_HOST ?=
#   make gdb GDB_HOST=192.168.1.50
GDB_HOST           ?=

# ------- GDB_EXTRA_ARGS -----------------------------------------------------
# Extra arguments appended to the gdb command line (power users), e.g. extra
# `-ex "command"` startup commands to auto-load and run.
#
# Examples:
#   GDB_EXTRA_ARGS ?=
#   make gdb GDB_EXTRA_ARGS='-ex "load" -ex "continue"'
GDB_EXTRA_ARGS     ?=


# ============================================================================
#  Board reset over JTAG  (`make reset-board`)
# ============================================================================
#
# `make reset-board` resets the SoC over the ICE/JTAG link in a one-shot OpenOCD
# batch (like `make board-info`) and exits - it does NOT hold the adapter, so do
# not run it while `make openocd` is up. It reuses the OPENOCD_* settings above.
#
# The SC598 target cfg uses `reset_config trst_only` (no SRST line wired to the
# ICE), so the reset runs the cfg's on-chip RCU + CTI warm system reset. It
# completes on a core that is in the boot ROM / U-Boot / bare metal. LIMITATION
# (verified on hardware): a core already running an OS - e.g. Linux from a
# previous `make boot` - CANNOT be reset this way; ADI's sequence aborts and the
# core resumes the OS. With no SRST to force it, the only reset then is a
# power-cycle. `make reset-board` reports that as COULD NOT RESET (it does not
# claim success); a busy/disconnected ICE is reported as a separate failure.

# ------- RESET_MODE ---------------------------------------------------------
# What state to leave the cores in after the reset:
#   halt   Reset, then leave the A55 HALTED at the reset vector - the clean,
#          deterministic state for a following `make boot` / JTAG load. The board
#          does NOT boot on its own afterwards (it sits halted). Default.
#   run    Reset, then run from the BMODE boot source. In JTAG/no-boot BMODE the
#          boot ROM just spins (nothing visibly boots); in QSPI/eMMC/SD BMODE the
#          board reboots into U-Boot -> Linux.
#   init   Like halt, but also run any OpenOCD reset-init events.
#
# Examples:
#   RESET_MODE ?= halt
#   make reset-board RESET_MODE=run
RESET_MODE         ?= halt


# ============================================================================
#  Serial console  (`make terminal`)
# ============================================================================
#
# `make terminal` opens a minicom serial console on the board's USB/UART — the
# "Terminal1" you watch U-Boot / Linux boot on, alongside `make openocd` and
# `make gdb`. It checks minicom is installed (and prints how to install it),
# resolves the serial port, and runs `minicom -D <port> -b <baud> -o`.
# Exit minicom with Ctrl-A then X.

# ------- SERIAL_PORT --------------------------------------------------------
# The serial device for the SC598 console. Empty -> `make terminal` auto-detects
# it (a single USB-serial port is used directly; if several are present it lists
# them and asks you to choose, since the board's FTDI bridge exposes multiple
# channels). See `make list-serial-ports`.
#
# Examples:
#   SERIAL_PORT ?=
#   make terminal SERIAL_PORT=/dev/ttyUSB0
SERIAL_PORT        ?=

# ------- SERIAL_BAUD --------------------------------------------------------
# Console baud rate. The ADSP-SC5xx default is 115200 (8N1).
#
# Examples:
#   SERIAL_BAUD ?= 115200
SERIAL_BAUD        ?= 115200

# ------- TERMINAL_SUDO ------------------------------------------------------
# Command prefix to run minicom when you lack serial access. Empty by default
# (assumes you are in the `dialout` group). Set to `sudo` otherwise — though
# adding yourself to dialout (sudo usermod -aG dialout $USER) is the cleaner fix.
#
# Examples:
#   TERMINAL_SUDO ?=
#   make terminal TERMINAL_SUDO=sudo
TERMINAL_SUDO      ?=

# ------- MINICOM_ARGS -------------------------------------------------------
# Extra arguments appended to the minicom command line (power users), e.g.
# `-C boot.log` to capture the session to a file.
#
# Examples:
#   MINICOM_ARGS ?=
#   make terminal MINICOM_ARGS='-C boot.log'
MINICOM_ARGS       ?=


# ============================================================================
#  Automated boot to Linux  (`make boot`)
# ============================================================================
#
# `make boot` collapses the three-terminal ADI JTAG bring-up (make openocd /
# make gdb / make terminal) into ONE hands-free command that drives the board to
# a Linux login prompt:
#
#   1. starts OpenOCD over the ICE (or reuses one already on OPENOCD_GDB_PORT);
#   2. GDB-loads U-Boot SPL, runs it (DDR init, then it spins in JTAG/no-boot
#      mode), then loads U-Boot proper and runs it - proper's board_init_r
#      asserts the Rev-E uart0-en (ADP5588 @ i2c2 0x34) so the console wakes;
#   3. owns the serial console (what you would watch in `make terminal`),
#      interrupts autoboot, sets up networking, ping-gates the link, tftp's the
#      fitImage into DDR and bootm's it;
#   4. waits for the `login:` prompt = success, then (by default) hands the live
#      console to minicom so you can log in.
#
# It REUSES the OPENOCD_*, GDB_*, SERIAL_* and BOARD_IP/HOST_IP/BOARD_NETMASK/
# BOARD_GATEWAY/BOARD_HOSTNAME/NFS_* settings above - no duplicate IP knobs.
#
# Prerequisites (make boot preflights each and names the fix if missing):
#   - a built image           : make image
#   - the fitImage staged      : make tftp        (sets up TFTP_DIR/fitImage)
#   - a running TFTP server    : make tftp-ensure  (sudo; serves udp/69)
#   - for METHOD=nfs, a rootfs : make nfs-setup     (exports NFS_DIR)
#   - board POWER-CYCLED, BMODE in JTAG/no-boot: the ICE can't reset a running
#     core, so re-running over a live Linux fails the attach. make boot detects
#     this and tells you to power-cycle (it cannot do so itself; `make
#     reset-board` can't either — ADI's reset aborts on a running core).
#
# Typical use (everything else taken from this file):
#   make boot
#   make boot BOOT_METHOD=ramdisk          # kernel smoke test, no NFS
#   make boot SERIAL_PORT=/dev/ttyUSB4     # pin the console, skip auto-probe

# ------- BOOT_METHOD --------------------------------------------------------
# How the rootfs is provided once the kernel (from the tftp'd fitImage) boots:
#   nfs       Mount the rootfs `make nfs-setup` exported over NFS -> a full
#             systemd login. The verified path; reaches `adsp-sc598-... login:`.
#   ramdisk   Boot only the fitImage's embedded initramfs -> a busybox shell
#             (NOT a full login:). Fewest prerequisites (no NFS). Good for a
#             quick "does the kernel come up" check.
#
# Examples:
#   BOOT_METHOD ?= nfs
#   make boot BOOT_METHOD=ramdisk
BOOT_METHOD        ?= nfs

# ------- BOOT_NETDEV --------------------------------------------------------
# The kernel network interface in the `ip=` bootarg (device field). eth0 on the
# SC598 SOM-EZKIT.
#
# Examples:
#   BOOT_NETDEV ?= eth0
BOOT_NETDEV        ?= eth0

# ------- BOOT_CONSOLE / BOOT_EARLYCON / BOOT_MEM ----------------------------
# Kernel cmdline console / earlycon / mem for the SC598. console/earlycon are
# board facts you rarely change: the console UART is ttySC0 @ 115200, the early
# console is the ADI UART at 0x31003000. BOOT_MEM is the kernel mem= for
# `make boot` and DERIVES from LINUX_MEM (the Linux <-> SHARC+ DDR split; see the
# LINUX_MEM section above) so the JTAG/NFS boot matches the built image. Override
# only to boot with a different cap than the image was built for.
#
# Examples:
#   BOOT_CONSOLE  ?= ttySC0,115200
#   BOOT_EARLYCON ?= adi_uart,0x31003000
#   BOOT_MEM      ?= $(LINUX_MEM)
BOOT_CONSOLE       ?= ttySC0,115200
BOOT_EARLYCON      ?= adi_uart,0x31003000
BOOT_MEM           ?= $(LINUX_MEM)

# ------- BOOT_FITIMAGE_ADDR / BOOT_FITIMAGE_NAME ----------------------------
# DDR scratch the fitImage is tftp'd to before `bootm`, and its filename on the
# TFTP server. 0x90000000 sits ABOVE the kernel's mem=224M window
# (0x80000000-0x8E000000) so `bootm` can unpack the FIT without the kernel
# clobbering the source. (Do NOT use 0x80000000 - that is inside the kernel RAM.)
#
# Examples:
#   BOOT_FITIMAGE_ADDR ?= 0x90000000
#   BOOT_FITIMAGE_NAME ?= fitImage
BOOT_FITIMAGE_ADDR ?= 0x90000000
BOOT_FITIMAGE_NAME ?= fitImage

# ------- BOOT_SPL_ELF / BOOT_PROPER_ELF -------------------------------------
# The two U-Boot stages GDB loads over JTAG. Empty -> auto-found in the deploy
# dir as u-boot-spl-<board>.elf and u-boot-proper-<board>.elf (the names the BSP
# produces). Override only to load a U-Boot from elsewhere.
#
# Examples:
#   BOOT_SPL_ELF    ?=
#   BOOT_PROPER_ELF ?=
BOOT_SPL_ELF       ?=
BOOT_PROPER_ELF    ?=

# ------- BOOT_SPL_SPIN_SYM --------------------------------------------------
# GDB breakpoint used to stop SPL AFTER it has initialised DDR but before the
# JTAG/no-boot spin, which is the safe moment to JTAG-load U-Boot proper (load
# it too early and proper's image fails to write because DDR is not up yet).
# board_boot_order is where the manual Ctrl-C reliably landed. Set EMPTY to fall
# back to a timed run-then-interrupt (BOOT_SPL_RUN_SECS).
#
# Examples:
#   BOOT_SPL_SPIN_SYM ?= board_boot_order
#   make boot BOOT_SPL_SPIN_SYM=          # timed interrupt instead
BOOT_SPL_SPIN_SYM  ?= board_boot_order

# ------- BOOT_SPL_RUN_SECS --------------------------------------------------
# Seconds to let SPL run before interrupting it, used only when BOOT_SPL_SPIN_SYM
# is empty (the timed fallback). Long enough to finish DDR init.
#
# Examples:
#   BOOT_SPL_RUN_SECS ?= 4
BOOT_SPL_RUN_SECS  ?= 4

# ------- BOOT_GDB_RESET -----------------------------------------------------
# Non-empty/1 -> issue `monitor reset halt` before loading SPL, for a clean
# start. Set to 0 if your setup needs the boot-ROM to idle first (then a
# power-cycle on BMODE=JTAG is the reset instead).
#
# Examples:
#   BOOT_GDB_RESET ?= 1
BOOT_GDB_RESET     ?= 1

# ------- BOOT_UBOOT_PROMPT / BOOT_UBOOT_TIMEOUT -----------------------------
# The U-Boot prompt string to wait for, and how long (seconds) to allow for the
# JTAG load + reaching that prompt.
#
# Examples:
#   BOOT_UBOOT_PROMPT  ?= "=> "
#   BOOT_UBOOT_TIMEOUT ?= 90
BOOT_UBOOT_PROMPT  ?= =>
BOOT_UBOOT_TIMEOUT ?= 90

# ------- BOOT_LOGIN_REGEX / BOOT_LINUX_TIMEOUT ------------------------------
# Regex marking success (the login prompt) and how long (seconds) to wait for it
# after `bootm`. The default matches both `login:` and `<host> login:`.
#
# Examples:
#   BOOT_LOGIN_REGEX  ?= login:
#   BOOT_LINUX_TIMEOUT ?= 180
BOOT_LOGIN_REGEX   ?= login:
BOOT_LINUX_TIMEOUT ?= 180

# ------- BOOT_AUTO_LOGIN / BOOT_USER / BOOT_PASS ----------------------------
# If BOOT_AUTO_LOGIN is non-empty, `make boot` types BOOT_USER (and BOOT_PASS if
# set) at the login prompt. On the stock ADI dev image the user is `root` with
# password `adi`. Leave AUTO_LOGIN empty to just stop at the prompt.
#
# Examples:
#   BOOT_AUTO_LOGIN ?=
#   make boot BOOT_AUTO_LOGIN=1 BOOT_USER=root BOOT_PASS=adi
BOOT_AUTO_LOGIN    ?=
BOOT_USER          ?= root
BOOT_PASS          ?= adi

# ------- BOOT_INTERACTIVE ---------------------------------------------------
# After login is reached: non-empty/1 -> release JTAG and hand the live console
# to minicom (like `make terminal`) so you can use the shell immediately; set to
# 0 to print success and exit (the board keeps running; attach later with
# `make terminal`). Set 0 for unattended/CI use.
#
# Examples:
#   BOOT_INTERACTIVE ?= 1
#   make boot BOOT_INTERACTIVE=0
BOOT_INTERACTIVE   ?= 1

# ------- BOOT_AUTO_STAGE ----------------------------------------------------
# Non-empty -> if the fitImage is not staged in TFTP_DIR, run the (non-sudo)
# `make tftp` staging automatically during preflight. The privileged steps
# (tftp-ensure, nfs-setup) are never auto-run.
#
# Examples:
#   BOOT_AUTO_STAGE ?=
#   make boot BOOT_AUTO_STAGE=1
BOOT_AUTO_STAGE    ?=


# ============================================================================
#  GitHub release publishing (`make publish`)
# ============================================================================
#
# The `make publish` target uses the `gh` CLI to upload the built SD-card
# image as an asset on a GitHub release. Prerequisites:
#
#   1. `gh` (GitHub CLI) installed:  https://cli.github.com/
#      Debian/Ubuntu: sudo apt install gh
#
#   2. Authenticate one of two ways:
#        gh auth login                  (interactive)
#        export GH_TOKEN=ghp_xxxxxxxx   (CI / non-interactive)
#
#   3. The target repository (GH_REPO) must already exist on GitHub. The
#      release tag (GH_VERSION) is created automatically if it does not
#      exist yet, anchored to GH_TARGET (typically `main`).
#
# The publisher will:
#   - Prefer the deploy-dir .wic.gz over output/sdcard.img (smaller upload).
#   - Stage the asset as: <GH_PROJECT>-<MACHINE>-<GH_VERSION>.wic.gz
#   - Upload a sibling SHA256 sidecar.
#   - Auto-generate release notes (machine, image recipe, sha256, flashing
#     instructions) if GH_NOTES_FILE is not set.
#
# Typical workflow:
#
#   make image                                      # build
#   make publish GH_VERSION=1.0.0                   # release
#

# ------- GH_REPO ------------------------------------------------------------
# The GitHub repository in `owner/repo` form where the release will be
# created. REQUIRED. Default is empty so the user must make an explicit
# choice (typo here = release going to the wrong repo).
#
# Examples:
#   GH_REPO ?= dg1sbg/adsp-sc598-images
#   GH_REPO ?= mycompany/sc598-platform
GH_REPO       ?=


# ------- GH_PROJECT ---------------------------------------------------------
# Short project label used in asset filenames and the release title.
#
# Asset will be named: <GH_PROJECT>-<MACHINE>-<GH_VERSION>.<ext>
# Release title:       "<GH_PROJECT> <GH_VERSION>"
#
# Default `adsp-sc598` matches this project directory.
#
# Examples:
#   GH_PROJECT ?= adsp-sc598
#   GH_PROJECT ?= edge-gateway
GH_PROJECT    ?= adsp-sc598


# ------- GH_VERSION ---------------------------------------------------------
# The release tag/version. REQUIRED. Must be a strict Semantic Versioning
# 2.0.0 string. The "v" prefix is NOT allowed (use the canonical semver form
# - see https://semver.org/spec/v2.0.0.html). bin/publish-release.sh
# validates the value against the full semver grammar before doing anything;
# malformed versions are rejected with an explanatory error.
#
# Grammar:  MAJOR.MINOR.PATCH[-prerelease][+buildmetadata]
#
# Examples:
#   make publish GH_VERSION=1.0.0
#   make publish GH_VERSION=0.1.0
#   make publish GH_VERSION=1.0.0-rc.1 GH_PRERELEASE=1
#   make publish GH_VERSION=1.0.0-alpha+exp.sha.5114f85
#   make publish GH_VERSION=2.0.0-rc.2+build.42
#
# Rejected (illustrative):
#   v1.0.0    -- 'v' prefix forbidden
#   1.0       -- missing PATCH
#   01.0.0    -- leading zero in MAJOR
#   1.0.0_b   -- underscores not allowed in identifiers
GH_VERSION    ?=


# ------- GH_TARGET ----------------------------------------------------------
# The git ref the new tag will anchor to. Default `main`. Use a specific
# commit SHA if you want the release pinned to an exact commit instead of
# whatever HEAD of `main` happens to be at publish time.
#
# Examples:
#   GH_TARGET ?= main
#   GH_TARGET ?= release/2024-q2
#   make publish GH_TARGET=1a2b3c4d
GH_TARGET     ?= main


# ------- GH_NOTES_FILE ------------------------------------------------------
# Path to a markdown file containing the release notes body. If empty
# (default), bin/publish-release.sh generates a notes file containing build
# metadata, sha256 sum, and flashing instructions.
#
# Use a custom notes file when you want curated changelogs.
#
# Examples:
#   GH_NOTES_FILE ?= release-notes/1.0.0.md
#   make publish GH_NOTES_FILE=./CHANGELOG-v1.0.md
GH_NOTES_FILE ?=


# ------- GH_DRAFT -----------------------------------------------------------
# If non-empty, the release is created as a draft (visible only to repo
# collaborators, not published to the public release feed). Use this to
# stage a release for review before going live.
#
# Examples:
#   make publish GH_DRAFT=1
GH_DRAFT      ?=


# ------- GH_PRERELEASE ------------------------------------------------------
# If non-empty, the release is marked as a prerelease (latest-release feed
# skips it). Use for RCs, alphas, betas, anything not production-ready.
#
# Examples:
#   make publish GH_VERSION=1.0.0-rc.1 GH_PRERELEASE=1
GH_PRERELEASE ?=

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

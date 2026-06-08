# Makefile - ADSP-SC598 Yocto build with auto-generated custom-app layer.
#
# Standard flow from a clean checkout:
#   make init         - download `repo`, repo init the ADI BSP manifest
#   make fetch        - repo sync the ADI BSP sources (auto-runs init first)
#   make image        - configure build dir + regen meta-custom-apps + bitbake
#   make sdcard       - extract wic.gz to output/sdcard.img
#   make flash DEV=/dev/sdX
#
# All user-tunable settings (MACHINE, DISTRO, IMAGE, BUILDDIR, GH_*) live in
# ./config.mk - edit that file or override on the cmdline (e.g.
# `make image MACHINE=adsp-sc594-som-ezkit`).

SHELL := /bin/bash
# NB: no -u here. poky's oe-init-build-env touches unset vars ($BBSERVER, $ZSH_NAME)
# without defaults, which would die under nounset. Our own scripts in bin/ set
# -euo pipefail themselves where they want strict behaviour.
.SHELLFLAGS := -e -o pipefail -c

PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BIN_DIR      := $(PROJECT_ROOT)/bin
OVERLAYS_DIR := $(PROJECT_ROOT)/overlays
SRC_DIR      := $(PROJECT_ROOT)/src
APPS_DIR     := $(SRC_DIR)/apps
LAYERS_DIR   := $(SRC_DIR)/layers
IMAGES_DIR   := $(PROJECT_ROOT)/images
TOOLING_DIR  := $(PROJECT_ROOT)/tooling

# All user-tunable settings (MACHINE, DISTRO, IMAGE, BUILDDIR, GH_*).
# Edit config.mk to change defaults; cmdline overrides always win.
include $(PROJECT_ROOT)/config.mk

# Normalize BUILDDIR: a previously-sourced oe-init-build-env may have exported
# BUILDDIR=<absolute-path>; reduce to basename so $(SRC_DIR)/$(BUILDDIR) does
# not double up. `:=` here beats env but loses to a cmdline BUILDDIR=foo.
BUILDDIR     := $(notdir $(BUILDDIR))
unexport BUILDDIR
BUILD_DIR    := $(SRC_DIR)/$(BUILDDIR)

CUSTOM_LAYER := $(LAYERS_DIR)/meta-custom-apps

.DEFAULT_GOAL := help

.PHONY: help host-setup init fetch configure apps image sbom sbom-collect sdcard flash tftp tftp-status tftp-ensure tftp-test nfs-setup nfs-status sdk openocd gdb board-info reset-board terminal boot publish new-app list-apps list-serial-ports detect-console-port clean distclean shell distro-info update-tooling

help:
	@echo "ADSP-SC598 Yocto build"
	@echo ""
	@echo "Targets:"
	@echo "  make host-setup                  Install host build prerequisites (apt/dnf/pacman/zypper); DRY_RUN=1 to preview"
	@echo "  make init                        Download repo, repo init the ADI BSP manifest"
	@echo "  make fetch                       repo sync the ADI BSP sources (auto-runs init first)"
	@echo "  make configure                   Configure build dir, enable SD-card boot"
	@echo "  make apps                        Regenerate meta-custom-apps from src/apps/"
	@echo "  make image [IMAGE=name]          bitbake the image and copy wic.gz to images/"
	@echo "                                   Optional: LINUX_MEM=224M (RAM for Linux; SHARC+ gets the rest), LINUX_RT=1 (PREEMPT_RT kernel)"
	@echo "  make sbom                        (Re)generate the image's SPDX SBOM into images/"
	@echo "  make sbom-collect                Copy the last build's SPDX SBOMs into images/ (helper; run by image/sbom)"
	@echo "  make sdcard                      Decompress wic.gz to images/sdcard.img"
	@echo "  make flash DEV=/dev/sdX          dd images/sdcard.img to /dev/sdX (with safety prompt)"
	@echo "  make tftp                        Copy fitImage/kernel/dtb/initrd to TFTP_DIR for net-boot"
	@echo "                                   Required: TFTP_DIR=/srv/tftp/... (or set in config.mk)"
	@echo "  make tftp-status                 Show TFTP server state: listen addr:port, served dir, config file"
	@echo "  make tftp-ensure                 Ensure a TFTP server is running (starts an installed one; sudo)"
	@echo "  make tftp-test                   List served files + verify one downloads via TFTP (loopback)"
	@echo "                                   Optional: TFTP_TEST_FILE=<name> TFTP_TEST_HOST=<ip>"
	@echo "  make nfs-setup                   Export the built rootfs over NFS for NFS-root dev (sudo)"
	@echo "                                   Required: NFS_DIR=/srv/nfs/...  (set in config.mk); NFS_FORCE=1 re-extracts"
	@echo "  make nfs-status                  Show NFS export state + the exact u-boot NFS-root bootargs"
	@echo "  make sdk                         Build the ADI SDK (populate_sdk) + install to SDK_INSTALL_DIR"
	@echo "                                   Provides OpenOCD/GDB for 'make openocd'; SDK_SUDO=sudo for /opt"
	@echo "  make openocd                     Start OpenOCD over ADI ICE JTAG (SC598); serves GDB on :3333"
	@echo "                                   Optional: OPENOCD_ICE=ice1000|ice2000 OPENOCD_SUDO=sudo (see config.mk)"
	@echo "  make gdb                         Attach the SDK's aarch64 GDB to a running 'make openocd' (:3333)"
	@echo "                                   Optional: GDB_ELF=<u-boot.elf> GDB_HOST=<ip> (see config.mk)"
	@echo "  make board-info                  Probe the board over JTAG: IDCODEs, DAP/ROM, regs, silicon rev, boot mode, RAM"
	@echo "                                   Self-contained OpenOCD run; not while 'make openocd' holds the adapter"
	@echo "  make reset-board                 Reset the SC598 over JTAG in one shot (ADI RCU+CTI warm reset; self-contained OpenOCD)"
	@echo "                                   A running OS can't be reset (power-cycle for that). RESET_MODE=halt|run|init (default halt)"
	@echo "  make terminal                    Open a minicom serial console to the SC598 (auto-detects port)"
	@echo "                                   Optional: SERIAL_PORT=/dev/ttyUSBx SERIAL_BAUD=115200"
	@echo "  make boot                        Drive the board to a Linux login over JTAG, hands-free (openocd+gdb+console)"
	@echo "                                   Prereqs: make image; make tftp; make tftp-ensure; (nfs) make nfs-setup"
	@echo "                                   Optional: BOOT_METHOD=nfs|ramdisk SERIAL_PORT=... BOOT_INTERACTIVE=0 (see config.mk)"
	@echo "  make publish                     Stage versioned asset, [optionally TFTP-stage], upload GH release"
	@echo "                                   Required: GH_REPO=owner/repo  GH_VERSION=X.Y.Z (strict SemVer 2.0.0, NO 'v' prefix)"
	@echo "                                   Optional: GH_PROJECT GH_TARGET GH_NOTES_FILE GH_DRAFT=1 GH_PRERELEASE=1"
	@echo "  make new-app NAME=foo [KIND=k]   Scaffold app skeleton"
	@echo "                                   KIND: local-source | git | prebuilt-binary | prebuilt-tarball"
	@echo "  make list-apps                   List configured apps"
	@echo "  make list-serial-ports           List serial ports + by-id names, USB chip/channel (FT4232H JTAG tagged)"
	@echo "  make detect-console-port         Probe the serial ports to find the SC598 console (board must be booted)"
	@echo "  make clean                       Remove tmp/ (keep sstate)"
	@echo "  make distclean                   Also remove sstate-cache and downloads"
	@echo "  make shell                       Subshell with bitbake env sourced"
	@echo "  make distro-info                 Print the Yocto distro (name/version/codename) + build context + layers"
	@echo "  make update-tooling              Rebuild the self-extracting tooling archive into tooling/"
	@echo "  make help                        Show this target list (the default goal)"
	@echo ""
	@echo "Settings: MACHINE=$(MACHINE) DISTRO=$(DISTRO) IMAGE=$(IMAGE) BUILDDIR=$(BUILDDIR)"

# Install the host build prerequisites (Yocto build deps + this harness's tools)
# for the detected distro - apt/dnf/pacman/zypper. Best-effort with a verify step;
# uses sudo as needed. DRY_RUN=1 prints the package plan without installing.
host-setup:
	@bash "$(BIN_DIR)/host-setup.sh" $(if $(DRY_RUN),--dry-run)

init:
	@bash "$(BIN_DIR)/repo-init.sh" \
		--src-dir "$(SRC_DIR)" \
		--repo-tool-url "$(REPO_TOOL_URL)" \
		--manifest-url "$(REPO_MANIFEST_URL)" \
		--manifest-branch "$(REPO_MANIFEST_BRANCH)" \
		--manifest-file "$(REPO_MANIFEST_FILE)"

# `fetch` is just `repo sync`. If the client has never been initialised
# (no src/.repo), bootstrap it first by delegating to the `init` target so
# the download + `repo init` logic lives in exactly one place. Cmdline
# overrides (e.g. REPO_MANIFEST_BRANCH=...) propagate to the sub-make.
fetch:
	@if [ ! -d "$(SRC_DIR)/.repo" ]; then \
		echo "[fetch] src/.repo missing - bootstrapping via 'make init'"; \
		$(MAKE) --no-print-directory init; \
	fi
	@echo "[fetch] repo sync"
	@cd "$(SRC_DIR)" && ./bin/repo sync

configure:
	@bash "$(BIN_DIR)/configure-build.sh" \
		--project-root "$(PROJECT_ROOT)" \
		--builddir "$(BUILDDIR)" \
		--machine "$(MACHINE)" \
		--distro "$(DISTRO)" \
		--som-rev "$(SOM_REV)" \
		--crr-rev "$(CRR_REV)" \
		--linux-mem "$(LINUX_MEM)" \
		--ddr-size "$(DDR_SIZE)" \
		--ddr-base "$(DDR_BASE)" \
		--board-dns "$(BOARD_DNS)" \
		--linux-rt "$(LINUX_RT)"

apps:
	@python3 "$(BIN_DIR)/gen-apps.py" generate \
		--apps-dir "$(APPS_DIR)" \
		--layer-dir "$(CUSTOM_LAYER)" \
		--default-image "$(IMAGE)"

image: configure apps
	@echo "[image] Building $(IMAGE) for $(MACHINE) ..."
	@cd "$(SRC_DIR)" && \
		source ./setup-environment --builddir "$(BUILDDIR)" >/dev/null && \
		bitbake "$(IMAGE)"
	@mkdir -p "$(IMAGES_DIR)"
	@DEPLOY="$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)"; \
	OUT="$(IMAGES_DIR)/$(IMAGE)-$(MACHINE).rootfs.wic.gz"; \
	WIC_GZ=""; \
	for cand in "$$DEPLOY/$(IMAGE)-$(MACHINE).rootfs.wic.gz" \
	            "$$DEPLOY/$(IMAGE)-$(MACHINE).wic.gz"; do \
		if [ -e "$$cand" ]; then WIC_GZ="$$cand"; break; fi; \
	done; \
	if [ -n "$$WIC_GZ" ]; then \
		cp -L "$$WIC_GZ" "$$OUT"; \
		echo "[image] Copied $$(basename $$WIC_GZ) -> $$OUT ($$(du -h $$OUT | cut -f1))"; \
	else \
		echo "[image] WARNING: no $(IMAGE)-$(MACHINE)*.wic.gz found in $$DEPLOY - skipping copy"; \
	fi
	@$(MAKE) --no-print-directory sbom-collect

# (Re)generate the image's SPDX SBOM - a byproduct of the create-spdx class
# enabled in overlays/local.conf.fragment - and copy it into images/. bitbake is
# incremental, so this only re-runs the SPDX tasks that are stale.
sbom: configure apps
	@echo "[sbom] (Re)generating the SPDX SBOM via bitbake $(IMAGE) ..."
	@cd "$(SRC_DIR)" && \
		source ./setup-environment --builddir "$(BUILDDIR)" >/dev/null && \
		bitbake "$(IMAGE)"
	@$(MAKE) --no-print-directory sbom-collect

# Internal helper: copy the image SPDX artifacts from the bitbake deploy dir into
# images/. Shared by `sbom` and `image`.
sbom-collect:
	@mkdir -p "$(IMAGES_DIR)"
	@DEPLOY="$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)"; \
	found=0; \
	for f in "$$DEPLOY"/*.spdx.json "$$DEPLOY"/*.spdx.tar.zst; do \
		[ -e "$$f" ] || continue; \
		cp -L "$$f" "$(IMAGES_DIR)/"; \
		echo "[sbom] $$(basename $$f) -> images/ ($$(du -h $$f | cut -f1))"; \
		found=1; \
	done; \
	if [ "$$found" = "0" ]; then \
		echo "[sbom] WARNING: no *.spdx.json / *.spdx.tar.zst in $$DEPLOY"; \
		echo "[sbom]          (need INHERIT += \"create-spdx\" active and a completed image build)"; \
	fi

sdcard:
	@mkdir -p "$(IMAGES_DIR)"
	@WIC_GZ=""; \
	for cand in "$(IMAGES_DIR)/$(IMAGE)-$(MACHINE).rootfs.wic.gz" \
	            "$(IMAGES_DIR)/$(IMAGE)-$(MACHINE).wic.gz" \
	            "$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)/$(IMAGE)-$(MACHINE).rootfs.wic.gz" \
	            "$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)/$(IMAGE)-$(MACHINE).wic.gz"; do \
		if [ -e "$$cand" ]; then WIC_GZ="$$cand"; break; fi; \
	done; \
	if [ -z "$$WIC_GZ" ]; then \
		echo "[sdcard] ERROR: $(IMAGE)-$(MACHINE)*.wic.gz not found in images/ or deploy dir."; \
		echo "[sdcard] Run 'make image' first."; \
		exit 1; \
	fi; \
	echo "[sdcard] Decompressing $$WIC_GZ -> $(IMAGES_DIR)/sdcard.img"; \
	gunzip -fkc "$$WIC_GZ" > "$(IMAGES_DIR)/sdcard.img"; \
	echo "[sdcard] Done: $(IMAGES_DIR)/sdcard.img ($$(du -h $(IMAGES_DIR)/sdcard.img | cut -f1))"

flash:
	@if [ -z "$(DEV)" ]; then \
		echo "Usage: make flash DEV=/dev/sdX"; \
		exit 1; \
	fi
	@bash "$(BIN_DIR)/flash-sdcard.sh" "$(DEV)" "$(IMAGES_DIR)/sdcard.img"

tftp:
	@if [ -z "$(TFTP_DIR)" ]; then \
		echo "ERROR: TFTP_DIR is not set."; \
		echo "       Configure it in config.mk or pass on cmdline:"; \
		echo "       make tftp TFTP_DIR=/srv/tftp/adsp-sc598"; \
		exit 1; \
	fi
	@bash "$(BIN_DIR)/tftp-stage.sh" \
		--tftp-dir "$(TFTP_DIR)" \
		--deploy-dir "$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)" \
		--images-dir "$(IMAGES_DIR)" \
		--machine "$(MACHINE)"

# Inspect / bring up the host TFTP daemon that serves the netboot files. TFTP_DIR
# is optional here: when set, the script cross-checks it against the dir the
# server actually serves and warns on a mismatch (the classic "staged files the
# board never sees" footgun).
tftp-status:
	@bash "$(BIN_DIR)/tftp-server.sh" status \
		$(if $(strip $(TFTP_DIR)),--tftp-dir "$(TFTP_DIR)")

tftp-ensure:
	@bash "$(BIN_DIR)/tftp-server.sh" ensure \
		$(if $(strip $(TFTP_DIR)),--tftp-dir "$(TFTP_DIR)")

# tftp-test operates on the dir the *server* serves (discovered from its config),
# not TFTP_DIR, so it does not take --tftp-dir. The optional TFTP_TEST_FILE /
# TFTP_TEST_HOST cmdline vars are forwarded into the recipe's environment (make
# variables are not otherwise visible to the script).
tftp-test:
	@TFTP_TEST_FILE="$(TFTP_TEST_FILE)" TFTP_TEST_HOST="$(TFTP_TEST_HOST)" \
		bash "$(BIN_DIR)/tftp-server.sh" test

# Export the built rootfs over NFS so the board can NFS-root mount it (fast dev
# loop: edit under NFS_DIR, reboot, live). `nfs-setup` needs root -> NFS_SUDO; the
# rootfs tarball is derived from the deploy dir. `nfs-status` (no root) shows the
# export state and prints the exact u-boot bootargs (ip=.../nfsroot=..., NO root=).
nfs-setup:
	@if [ -z "$(NFS_DIR)" ]; then \
		echo "ERROR: NFS_DIR is not set."; \
		echo "       Set it in config.mk or pass on cmdline:"; \
		echo "       make nfs-setup NFS_DIR=/srv/nfs/sc598-rootfs"; \
		exit 1; \
	fi
	@$(NFS_SUDO) bash "$(BIN_DIR)/nfs-server.sh" setup \
		--nfs-dir "$(NFS_DIR)" \
		--deploy-dir "$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)" \
		--image "$(IMAGE)" \
		--machine "$(MACHINE)" \
		--nfs-vers "$(NFS_VERS)" \
		$(if $(strip $(NFS_ALLOW)),--allow "$(NFS_ALLOW)") \
		$(if $(strip $(HOST_IP)),--host-ip "$(HOST_IP)") \
		$(if $(strip $(BOARD_IP)),--board-ip "$(BOARD_IP)") \
		$(if $(strip $(BOARD_NETMASK)),--netmask "$(BOARD_NETMASK)") \
		$(if $(strip $(BOARD_GATEWAY)),--gateway "$(BOARD_GATEWAY)") \
		$(if $(strip $(BOARD_HOSTNAME)),--hostname "$(BOARD_HOSTNAME)") \
		$(if $(strip $(NFS_FORCE)),--force)

nfs-status:
	@bash "$(BIN_DIR)/nfs-server.sh" status \
		--nfs-dir "$(NFS_DIR)" \
		--deploy-dir "$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)" \
		--image "$(IMAGE)" \
		--machine "$(MACHINE)" \
		--nfs-vers "$(NFS_VERS)" \
		$(if $(strip $(NFS_ALLOW)),--allow "$(NFS_ALLOW)") \
		$(if $(strip $(HOST_IP)),--host-ip "$(HOST_IP)") \
		$(if $(strip $(BOARD_IP)),--board-ip "$(BOARD_IP)") \
		$(if $(strip $(BOARD_NETMASK)),--netmask "$(BOARD_NETMASK)") \
		$(if $(strip $(BOARD_GATEWAY)),--gateway "$(BOARD_GATEWAY)") \
		$(if $(strip $(BOARD_HOSTNAME)),--hostname "$(BOARD_HOSTNAME)")

# Build the ADI SDK (Yocto populate_sdk) for SDK_IMAGE and install it into
# SDK_INSTALL_DIR via the self-extracting installer. Provides the cross-toolchain
# plus host OpenOCD/GDB that `make openocd` uses. Heavy first run, incremental
# after. Installing under /opt needs SDK_SUDO=sudo.
sdk: configure apps
	@echo "[sdk] Building the SDK (populate_sdk) for $(SDK_IMAGE) ..."
	@cd "$(SRC_DIR)" && \
		source ./setup-environment --builddir "$(BUILDDIR)" >/dev/null && \
		bitbake "$(SDK_IMAGE)" -c populate_sdk
	@bash "$(BIN_DIR)/sdk-install.sh" \
		--deploy-sdk-dir "$(BUILD_DIR)/tmp/deploy/sdk" \
		--install-dir "$(SDK_INSTALL_DIR)" \
		--openocd-bin "$(OPENOCD_BIN)" \
		$(if $(strip $(SDK_SUDO)),--sudo "$(SDK_SUDO)")

# Start the ADI fork of OpenOCD over a JTAG emulator (ICE-1000/2000) to debug the
# SC598 / load U-Boot via GDB on :$(OPENOCD_GDB_PORT). OpenOCD + its .cfg scripts
# come from the ADI SDK (build + install it with `make sdk`). Runs in the
# foreground until Ctrl-C. All paths/options are OPENOCD_* vars in config.mk.
openocd:
	@bash "$(BIN_DIR)/openocd-run.sh" \
		--openocd-bin "$(OPENOCD_BIN)" \
		--scripts-dir "$(OPENOCD_SCRIPTS)" \
		--ice "$(OPENOCD_ICE)" \
		--target "$(OPENOCD_TARGET)" \
		--gdb-port "$(OPENOCD_GDB_PORT)" \
		--machine "$(MACHINE)" \
		$(if $(strip $(OPENOCD_SUDO)),--sudo "$(OPENOCD_SUDO)") \
		$(if $(strip $(OPENOCD_EXTRA_ARGS)),--extra "$(OPENOCD_EXTRA_ARGS)")

# Attach the SDK's aarch64 GDB to the OpenOCD that `make openocd` is running
# (target extended-remote :$(OPENOCD_GDB_PORT)). Run this in a SECOND terminal
# while `make openocd` holds the first. Loads GDB_ELF (or an auto-found
# u-boot-spl-<board>.elf from the deploy dir) so you can `load` U-Boot, then `c`.
gdb:
	@bash "$(BIN_DIR)/gdb-run.sh" \
		--gdb-bin "$(GDB_BIN)" \
		--host "$(GDB_HOST)" \
		--port "$(OPENOCD_GDB_PORT)" \
		--elf "$(GDB_ELF)" \
		--deploy-dir "$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)" \
		--machine "$(MACHINE)" \
		$(if $(strip $(GDB_EXTRA_ARGS)),--extra "$(GDB_EXTRA_ARGS)")

# Probe the connected SC598 over JTAG and print adapter, scan-chain IDCODEs,
# CoreSight DAP/ROM table, target state, Cortex-A55 registers, and key SC598
# ID/status registers (silicon rev, boot mode, DDR). Self-contained OpenOCD batch
# run - do NOT run while `make openocd` holds the adapter. Uses the OPENOCD_* vars.
board-info:
	@bash "$(BIN_DIR)/board-info.sh" \
		--openocd-bin "$(OPENOCD_BIN)" \
		--scripts-dir "$(OPENOCD_SCRIPTS)" \
		--ice "$(OPENOCD_ICE)" \
		--target "$(OPENOCD_TARGET)" \
		--machine "$(MACHINE)" \
		$(if $(strip $(OPENOCD_SUDO)),--sudo "$(OPENOCD_SUDO)")

# Reset the attached SC598 over the ICE/JTAG link in a one-shot OpenOCD batch
# (ADI's RCU+CTI warm reset; the SC598 cfg declares no SRST line) then exit.
# Reuses the OPENOCD_* settings; RESET_MODE (halt|run|init) picks the post-reset
# core state. LIMITATION: a core already running an OS (e.g. Linux from a previous
# `make boot`) cannot be reset this way - ADI's sequence aborts and the core
# resumes; reset-board reports COULD NOT RESET and you must power-cycle. It works
# on a core in the boot ROM / U-Boot / bare metal. Self-contained run - do NOT
# run while `make openocd` holds the adapter.
reset-board:
	@bash "$(BIN_DIR)/reset-board.sh" \
		--openocd-bin "$(OPENOCD_BIN)" \
		--scripts-dir "$(OPENOCD_SCRIPTS)" \
		--ice "$(OPENOCD_ICE)" \
		--target "$(OPENOCD_TARGET)" \
		--machine "$(MACHINE)" \
		--mode "$(RESET_MODE)" \
		$(if $(strip $(OPENOCD_SUDO)),--sudo "$(OPENOCD_SUDO)")

# Open a minicom serial console to the board's USB/UART (the "Terminal1" you
# watch boot on). Checks minicom is installed, auto-detects the port if
# SERIAL_PORT is unset, and runs minicom at SERIAL_BAUD. Ctrl-A X to exit.
terminal:
	@bash "$(BIN_DIR)/terminal-run.sh" \
		--port "$(SERIAL_PORT)" \
		--baud "$(SERIAL_BAUD)" \
		--list-script "$(BIN_DIR)/list-serial-ports.sh" \
		$(if $(strip $(TERMINAL_SUDO)),--sudo "$(TERMINAL_SUDO)") \
		$(if $(strip $(MINICOM_ARGS)),--extra "$(MINICOM_ARGS)")

# Drive the board all the way to a Linux login over JTAG, hands-free: start
# OpenOCD, GDB-load SPL then U-Boot proper, then own the serial console to set up
# networking, ping-gate, tftp the fitImage and bootm, and wait for `login:`.
# Collapses `make openocd` + `make gdb` + `make terminal` into one command.
# Reuses the OPENOCD_*/GDB_*/SERIAL_* vars and the BOOT_*/BOARD_*/NFS_* settings
# from config.mk. Prereqs (preflighted, with the fix named): make image; make
# tftp; make tftp-ensure; and for BOOT_METHOD=nfs, make nfs-setup.
boot:
	@bash "$(BIN_DIR)/boot-run.sh" \
		--bin-dir "$(BIN_DIR)" \
		--deploy-dir "$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)" \
		--images-dir "$(IMAGES_DIR)" \
		--machine "$(MACHINE)" \
		--openocd-bin "$(OPENOCD_BIN)" \
		--openocd-scripts "$(OPENOCD_SCRIPTS)" \
		--ice "$(OPENOCD_ICE)" \
		--target "$(OPENOCD_TARGET)" \
		--gdb-port "$(OPENOCD_GDB_PORT)" \
		--gdb-bin "$(GDB_BIN)" \
		--gdb-host "$(GDB_HOST)" \
		--spl-elf "$(BOOT_SPL_ELF)" \
		--proper-elf "$(BOOT_PROPER_ELF)" \
		--spl-spin-sym "$(BOOT_SPL_SPIN_SYM)" \
		--spl-run-secs "$(BOOT_SPL_RUN_SECS)" \
		--gdb-reset "$(BOOT_GDB_RESET)" \
		--serial-port "$(SERIAL_PORT)" \
		--serial-baud "$(SERIAL_BAUD)" \
		--method "$(BOOT_METHOD)" \
		--board-ip "$(BOARD_IP)" \
		--host-ip "$(HOST_IP)" \
		--netmask "$(BOARD_NETMASK)" \
		--gateway "$(BOARD_GATEWAY)" \
		--hostname "$(BOARD_HOSTNAME)" \
		--netdev "$(BOOT_NETDEV)" \
		--nfs-dir "$(NFS_DIR)" \
		--nfs-vers "$(NFS_VERS)" \
		--console "$(BOOT_CONSOLE)" \
		--earlycon "$(BOOT_EARLYCON)" \
		--mem "$(BOOT_MEM)" \
		--fit-addr "$(BOOT_FITIMAGE_ADDR)" \
		--fit-name "$(BOOT_FITIMAGE_NAME)" \
		--uboot-prompt "$(BOOT_UBOOT_PROMPT) " \
		--uboot-timeout "$(BOOT_UBOOT_TIMEOUT)" \
		--login-regex "$(BOOT_LOGIN_REGEX)" \
		--linux-timeout "$(BOOT_LINUX_TIMEOUT)" \
		--auto-login "$(BOOT_AUTO_LOGIN)" \
		--user "$(BOOT_USER)" \
		--password "$(BOOT_PASS)" \
		--interactive "$(BOOT_INTERACTIVE)" \
		--tftp-dir "$(TFTP_DIR)" \
		$(if $(strip $(OPENOCD_SUDO)),--openocd-sudo "$(OPENOCD_SUDO)") \
		$(if $(strip $(TERMINAL_SUDO)),--minicom-sudo "$(TERMINAL_SUDO)") \
		$(if $(strip $(BOOT_AUTO_STAGE)),--auto-stage)

# `make publish` also TFTP-stages when TFTP_DIR is non-empty. The $(if ...)
# evaluates at Makefile parse time, so the prereq list itself becomes
# `tftp` or empty depending on configuration.
publish: $(if $(strip $(TFTP_DIR)),tftp)
	@if [ -z "$(GH_REPO)" ] || [ -z "$(GH_VERSION)" ]; then \
		echo "Usage: make publish GH_REPO=owner/repo GH_VERSION=X.Y.Z (strict SemVer 2.0.0, no 'v' prefix)"; \
		echo "       Optional: GH_PROJECT=$(GH_PROJECT) GH_TARGET=$(GH_TARGET) GH_NOTES_FILE=... GH_DRAFT=1 GH_PRERELEASE=1"; \
		exit 1; \
	fi
	@bash "$(BIN_DIR)/publish-release.sh" \
		--repo "$(GH_REPO)" \
		--project "$(GH_PROJECT)" \
		--version "$(GH_VERSION)" \
		--target "$(GH_TARGET)" \
		--machine "$(MACHINE)" \
		--image-name "$(IMAGE)" \
		--deploy-dir "$(BUILD_DIR)/tmp/deploy/images/$(MACHINE)" \
		--images-dir "$(IMAGES_DIR)" \
		$(if $(GH_NOTES_FILE),--notes-file "$(GH_NOTES_FILE)") \
		$(if $(GH_DRAFT),--draft) \
		$(if $(GH_PRERELEASE),--prerelease)

new-app:
	@if [ -z "$(NAME)" ]; then \
		echo "Usage: make new-app NAME=foo [KIND=local-source|git|prebuilt-binary|prebuilt-tarball]"; \
		exit 1; \
	fi
	@python3 "$(BIN_DIR)/gen-apps.py" scaffold \
		--apps-dir "$(APPS_DIR)" \
		--name "$(NAME)" \
		--kind "$(or $(KIND),local-source)"

list-apps:
	@python3 "$(BIN_DIR)/gen-apps.py" list --apps-dir "$(APPS_DIR)"

list-serial-ports:
	@bash "$(BIN_DIR)/list-serial-ports.sh" --long

# Actively probe the serial ports to find which one is the SC598 console: open
# each USB-serial candidate, nudge it with a CR, and listen for output only the
# SOM console emits (U-Boot, login:, kernel banner, the adsp-sc598 hostname).
# Board-agnostic (doesn't assume the bridge chip) but the board must be powered
# and past the boot ROM. Skips JTAG ports. Prints the detected /dev/ttyUSBx on
# stdout so it can feed SERIAL_PORT.
detect-console-port:
	@bash "$(BIN_DIR)/detect-console-port.sh" \
		--baud "$(SERIAL_BAUD)" \
		--list-script "$(BIN_DIR)/list-serial-ports.sh" \
		--long

clean:
	@echo "[clean] Removing $(BUILD_DIR)/tmp/"
	@rm -rf "$(BUILD_DIR)/tmp"

distclean: clean
	@echo "[distclean] Removing sstate-cache, downloads, generated layer, and tooling/"
	@rm -rf "$(BUILD_DIR)/sstate-cache" "$(BUILD_DIR)/downloads" "$(SRC_DIR)/downloads"
	@rm -rf "$(CUSTOM_LAYER)" "$(TOOLING_DIR)"

shell:
	@echo "[shell] Sourcing bitbake env. Type 'exit' to leave."
	@cd "$(SRC_DIR)" && \
		bash -c 'source ./setup-environment --builddir "$(BUILDDIR)" >/dev/null 2>&1 && exec "$${SHELL:-bash}"'

# Print the Yocto distro identity (name / version / codename) + build context,
# queried live from bitbake. Sources the env, then bin/distro-info.sh runs
# `bitbake -e` and parses DISTRO_* + target vars (first run ~10-30s).
distro-info:
	@cd "$(SRC_DIR)" && \
		source ./setup-environment --builddir "$(BUILDDIR)" >/dev/null && \
		bash "$(BIN_DIR)/distro-info.sh" \
			--machine "$(MACHINE)" \
			--image "$(IMAGE)"

# Package the project tooling (Makefile, config.mk, bin/, overlays/, example
# app) into a self-extracting shell archive under tooling/. The bin/ script
# owns the contents + archive format; this target just pins the output path.
update-tooling:
	@bash "$(BIN_DIR)/make-tooling-archive.sh" -o "$(TOOLING_DIR)/adsp-sc598-tooling.sh"

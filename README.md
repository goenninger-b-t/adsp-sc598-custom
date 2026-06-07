# ADSP-SC598 Yocto Build Harness

A thin, `make`-driven harness around the Analog Devices SHARC-DSP Linux BSP
(Yocto/OpenEmbedded, **scarthgap** / Yocto 5.0 LTS) for the **ADSP-SC598**.
It turns the multi-step "download `repo`, sync dozens of git trees, hand-edit
`local.conf`, hand-write recipes, bitbake, dd to SD" dance into a handful of
idempotent targets — and it **auto-integrates your own applications** from a
simple `src/apps/<name>/app.yaml` manifest, with no Yocto recipe writing.

```sh
make init      # download Google's `repo`, repo init the ADI manifest
make fetch     # repo sync the BSP sources
make image     # configure the build, generate the app layer, bitbake
make sdcard    # decompress the wic.gz to images/sdcard.img
make flash DEV=/dev/sdX
```

---

## The target

The **ADSP-SC598** is a heterogeneous Analog Devices SoC pairing an ARM
Cortex-A55 applications processor with SHARC+ DSP core(s). This harness builds
the **Linux side** (the Cortex-A55): kernel, u-boot, root filesystem, and a
bootable SD-card / network-boot image. The DSP firmware toolchain (CCES) is out
of scope here.

Other boards in the same BSP family build from the identical flow — just change
`MACHINE` (see [Configuration](#configuration)).

---

## What you get

- **One-command bootstrap** of the entire ADI BSP via Google's `repo` tool and
  the `analogdevicesinc/lnxdsp-repo-manifest` manifest, pinned to a release.
- **Zero-recipe custom apps**: drop a `app.yaml` (and source, or a git URL, or a
  prebuilt binary) under `src/apps/`, and `make apps` generates a complete
  `meta-custom-apps` Yocto layer — recipes, a packagegroup, and a custom image
  that installs them all.
- **SD-card boot** out of the box (the build is configured for the MMC/wic boot
  path) plus a **TFTP/network-boot** staging helper with ready-to-paste u-boot
  commands.
- **TFTP server control & verification**: `make tftp-status` (is a server up,
  what address:port is it on, which dir does it serve, which config file),
  `make tftp-ensure` (start an installed one), and `make tftp-test` (list the
  served files and prove one actually downloads over TFTP).
- **NFS-root development**: `make nfs-setup` exports the freshly built rootfs
  from this host over NFS and `make nfs-status` prints the exact U-Boot
  `bootargs` to boot it — edit the rootfs live, reboot, no reflash.
- **JTAG bring-up & debug**: `make sdk` builds + installs the ADI SDK
  (cross-toolchain plus host OpenOCD/GDB) into a configurable path, and
  `make openocd` drives OpenOCD over an ICE-1000/ICE-2000 to load U-Boot via GDB
  — straight from ADI's getting-started procedure. `make board-info` probes the
  board's JTAG/CoreSight identity and silicon revision in one shot.
- **Safe flashing** (`make flash`) that refuses to clobber mounted system disks.
- **GitHub release publishing** (`make publish`) with strict SemVer validation
  and an auto-generated, checksummed release note.
- **A self-extracting archive of the harness itself** (`make update-tooling`) so
  you can hand the tooling to another machine without the multi-gig BSP.
- A **clean, complete `.gitignore`**: only the hand-written tooling and your app
  sources are tracked; the fetched BSP, build tree, and outputs are ignored.

---

## Repository layout

```
.
├── Makefile                       # entry point — every workflow target
├── config.mk                      # all user-tunable settings (documented inline)
├── config.mk.local                # worked-example machine settings (see "Example settings")
├── README.md                      # this file
├── README.local.md                # worked-example runbook: 3-terminal JTAG -> NFS-root login
├── docs/                          # extended docs (app.yaml manifest reference)
├── LICENSE.md                     # MIT license
├── sbom.spdx.jsonld               # SPDX 3.0.1 SBOM of the harness (JSON-LD)
├── bin/                           # automation scripts the Makefile calls
│   ├── host-setup.sh              #   make host-setup     — install host prerequisites (apt/dnf/pacman/zypper)
│   ├── repo-init.sh               #   make init           — fetch `repo`, repo init
│   ├── configure-build.sh         #   make configure      — build dir + overlays
│   ├── gen-apps.py                #   make apps/new-app/list-apps — app layer generator
│   ├── flash-sdcard.sh            #   make flash          — guarded dd to SD card
│   ├── tftp-stage.sh              #   make tftp           — net-boot artifact staging
│   ├── tftp-server.sh             #   make tftp-{status,ensure,test} — inspect/start/verify TFTP server
│   ├── nfs-server.sh              #   make nfs-{setup,status} — export rootfs over NFS / show bootargs
│   ├── sdk-install.sh             #   make sdk            — install the populate_sdk SDK
│   ├── openocd-run.sh             #   make openocd        — start OpenOCD (ADI ICE JTAG)
│   ├── gdb-run.sh                 #   make gdb            — attach SDK aarch64 GDB to OpenOCD (:3333)
│   ├── board-info.sh              #   make board-info     — JTAG probe (IDCODEs, DAP, regs, silicon rev)
│   ├── reset-board.sh             #   make reset-board    — JTAG reset (RCU+CTI warm reset over the ICE)
│   ├── terminal-run.sh            #   make terminal       — minicom serial console to the SC598
│   ├── boot-run.sh                #   make boot           — drive JTAG -> U-Boot -> Linux login (front end)
│   ├── boot-drive.py              #   make boot           — orchestration engine (OpenOCD + GDB + serial)
│   ├── publish-release.sh         #   make publish        — GitHub release upload
│   ├── list-serial-ports.sh       #   make list-serial-ports — present serial ports
│   ├── detect-console-port.sh     #   make detect-console-port — probe ports for the SC598 console
│   ├── distro-info.sh             #   make distro-info    — print distro name/version + build context
│   ├── make-tooling-archive.sh    #   make update-tooling — self-extracting archive
│   └── lib/
│       └── bootcmds.sh            #   shared U-Boot bootargs/boot-command emitter (boot + nfs-status)
├── overlays/                      # bitbake conf fragments applied to the build dir
│   ├── local.conf.fragment        #   SD-card boot, debug-tweaks, create-spdx (SBOM)
│   └── bblayers.conf.fragment     #   adds the meta-custom-apps + meta-custom-bsp layers
├── meta-custom-bsp/               # static, hand-maintained BSP layer (committed)
│   └── recipes-kernel/linux/      #   linux-adi bbappend: LINUX_MEM -> DT /memory + mem=
├── src/                           # workspace (almost entirely fetched/generated)
│   └── apps/                      #   YOUR apps — the one hand-written tree under src/
│       └── hello-world/           #   worked example (local-source, make build)
│
│   # everything below src/ is fetched/generated and git-ignored:
│   #   src/.repo/        repo metadata + manifest        (make init)
│   #   src/bin/repo      the repo launcher               (make init)
│   #   src/sources/      poky + meta-adi + ... BSP layers (make fetch)
│   #   src/downloads/    bitbake DL_DIR                  (make fetch/image)
│   #   src/layers/meta-custom-apps/  generated app layer (make apps)
│   #   src/build/        bitbake TMPDIR + sstate-cache   (make image)
│
├── images/                        # build outputs: *.wic.gz, sdcard.img   (git-ignored)
└── tooling/                       # self-extracting tooling archive       (git-ignored)
```

Tracked in git: `Makefile`, `config.mk`, `bin/`, `overlays/`, `meta-custom-bsp/`, `src/apps/`, and the
docs (`README.md`, `docs/`, `LICENSE.md`, `sbom.spdx.jsonld`). Everything else is
fetched, generated, or a build output — all re-creatable from the targets above.

---

## Prerequisites

> **Tip:** `make host-setup` installs everything below (the Yocto build deps + this
> harness's tools) for the detected distro — apt/dnf/pacman/zypper. Run it once on a
> fresh host; `make host-setup DRY_RUN=1` previews the package list first.

- A 64-bit Linux host that can run Yocto **scarthgap** (Ubuntu 22.04/24.04,
  Debian, etc.) with the standard OpenEmbedded build dependencies installed
  (`gawk wget git diffstat unzip texinfo gcc build-essential chrpath socat cpio
  python3 python3-pip python3-pexpect xz-utils debianutils iputils-ping
  python3-git python3-jinja2 libegl1-mesa libsdl1.2-dev python3-subunit zstd
  liblz4-tool file locales` — see the Yocto Project Quick Start for the
  authoritative list).
- **`curl`** — to download the `repo` launcher.
- **`python3` + PyYAML** (`python3-yaml`) — the app-layer generator parses
  `app.yaml`.
- **Git**, and a configured `git config user.name/email` (bitbake's `repo` and
  some recipes expect it).
- **~100 GB free disk** for `src/` (the build tree alone reaches ~90 GB) and a
  few GB of RAM headroom; a fast SSD makes a large difference.
- Optional: **`gh`** (GitHub CLI) for `make publish`; a **TFTP server**
  (tftpd-hpa / dnsmasq) for `make tftp`, and a TFTP client (`tftp` / `atftp` /
  `curl` / `busybox`) for `make tftp-test`; `sudo` for `make flash`; an
  **ICE-1000/ICE-2000** JTAG emulator plus the ADI SDK (`make sdk`) for
  `make openocd`; an **NFS server** (`nfs-kernel-server`) for `make nfs-setup`
  (NFS-root development).

> The harness does **not** vendor the BSP. `make init`/`make fetch` pull it from
> Analog Devices' GitHub (and `repo` from Google) at first run.

---

## Quick start

```sh
# 0. One-time: install host build prerequisites (apt/dnf/pacman/zypper)
make host-setup

# 1. Bootstrap the BSP (first run only; make fetch will also init if needed)
make init
make fetch

# 2. Build the default custom image for the default machine
make image                       # = configure + apps + bitbake adi-sc5xx-custom

# 3a. Boot from SD card
make sdcard                      # images/sdcard.img
make flash DEV=/dev/sdX          # guarded; type YES to confirm
make terminal                    # watch it boot on the serial console (Ctrl-A X to exit)

# 3b. …or boot over the network
make tftp TFTP_DIR=/srv/tftp/sc598
make tftp-status                 # is a TFTP server actually serving those files?

# 3c. …or bring up U-Boot over JTAG (needs an ICE-1000/2000 + the ADI SDK)
make sdk                         # build + install the SDK (OpenOCD/GDB), once
make openocd                     # start OpenOCD; connect GDB on :3333 to load U-Boot

# 4. (optional) publish the image as a GitHub release
make publish GH_REPO=you/sc598-images GH_VERSION=1.0.0
```

Run `make` with no arguments (or `make help`) for the full target list and the
current settings.

---

## Make targets

| Target | What it does |
|---|---|
| `make host-setup` | Install the host build prerequisites (Yocto build deps + this harness's tools) for the detected distro — **apt** (Debian/Ubuntu), **dnf** (Fedora/RHEL/Rocky/Alma, +EPEL/CRB), **pacman** (Arch), **zypper** (openSUSE/SLES). Best-effort + a verify step; uses `sudo`. `make host-setup DRY_RUN=1` previews the package list. |
| `make init` | Download the `repo` launcher (`REPO_TOOL_URL`) to `src/bin/repo`, then `repo init` against the ADI manifest. Creates `src/.repo/`. |
| `make fetch` | `repo sync` the BSP into `src/sources/`. Auto-runs `init` first if `src/.repo` is missing. |
| `make configure` | Initialise the bitbake build dir (`src/<BUILDDIR>`) and idempotently apply `overlays/` to `local.conf`/`bblayers.conf`. Requires `make fetch` first. |
| `make apps` | (Re)generate `src/layers/meta-custom-apps` from every `src/apps/<name>/app.yaml`. |
| `make image [IMAGE=name]` | `configure` + `apps` + `bitbake` the image, copy the `wic.gz` into `images/`, and collect the image's SPDX SBOM. |
| `make sbom` | (Re)generate the image's SPDX SBOM (via the `create-spdx` class) and copy it into `images/`. |
| `make sbom-collect` | Helper (run by `make image` / `make sbom`): copy the SPDX SBOMs from the last build's deploy dir into `images/` — no rebuild. |
| `make sdcard` | Decompress the `wic.gz` to `images/sdcard.img`. |
| `make flash DEV=/dev/sdX` | `dd` `images/sdcard.img` to the device, with mount-point safety checks and a typed `YES` confirmation. |
| `make tftp TFTP_DIR=...` | Stage `fitImage` / kernel / dtb / initrd into a TFTP root and write a `README.tftp-boot` with u-boot commands. |
| `make tftp-status` | Report whether a TFTP server (tftpd-hpa / atftpd / dnsmasq) is running, the **address:port** it listens on, the directory it serves, and its **config file** path. With `TFTP_DIR` set, warns if the server serves a *different* dir than you stage into. |
| `make tftp-ensure` | Ensure a TFTP server is running: no-op if one is up, else start an installed daemon (`sudo systemctl start`). Never auto-installs — prints install guidance if none is present. |
| `make tftp-test` | List the files in the server's served directory (filesystem view — TFTP has no directory-listing opcode) and verify retrieval by fetching the smallest file over TFTP from loopback and byte-comparing it to the source. Optional `TFTP_TEST_FILE` / `TFTP_TEST_HOST`. |
| `make nfs-setup` | Install `nfs-kernel-server`, extract the built rootfs into `NFS_DIR`, and export it (`no_root_squash`) so the board can NFS-root mount it. Needs root (`NFS_SUDO=sudo`). Idempotent — preserves live edits unless `--force`. |
| `make nfs-status` | Show whether the NFS server is up and `NFS_DIR` is exported, and print the exact U-Boot `bootargs` (`ip=…` / `nfsroot=…`, **no** `root=`) to boot this NFS root. |
| `make sdk` | Build the ADI SDK (`bitbake <image> -c populate_sdk`) and run its installer into `SDK_INSTALL_DIR` — the cross-toolchain plus host OpenOCD/GDB used by `make openocd`. `SDK_SUDO=sudo` to install under `/opt`. |
| `make openocd` | Start the ADI fork of OpenOCD over a JTAG emulator (ICE-1000/ICE-2000) to debug the SC598 and load U-Boot via GDB on `:3333`. OpenOCD ships in the ADI SDK; all paths/options are `config.mk` vars (`OPENOCD_*`, `SDK_*`). |
| `make gdb` | Attach the SDK's aarch64 cross-GDB to the OpenOCD that `make openocd` is running (`target extended-remote :3333`) — run it in a **second terminal**. Auto-loads `GDB_ELF` or `u-boot-spl-<board>.elf` so you can `load` U-Boot into RAM. |
| `make board-info` | Probe the connected board over JTAG in one shot (self-contained OpenOCD batch): scan-chain TAP IDCODEs, CoreSight DAP/ROM table, target state, Cortex-A55 registers, SC598 ID/status registers (silicon revision, boot mode, DDR controllers), and a decoded **RAM map** — it detects every populated DDR controller (DMC) live, reports each bank's base + size, and sums the total. Don't run while `make openocd` holds the adapter. |
| `make reset-board` | Reset the SC598 over the ICE/JTAG link in one shot — a self-contained OpenOCD batch running the SC598 cfg's on-chip **RCU+CTI warm reset** (the part has no SRST line). **Limitation (verified):** a core already running an OS (e.g. Linux from a previous `make boot`) **cannot** be reset this way — ADI's sequence aborts and the core resumes, so it reports `COULD NOT RESET` and you must power-cycle. Completes on a core in the boot ROM / U-Boot / bare metal. `RESET_MODE=halt` (default), `run` (run from the BMODE boot source), or `init`. Don't run while `make openocd` holds the adapter. |
| `make terminal` | Open a **minicom** serial console to the SC598 over its USB/UART. Checks minicom is installed (prints how to install it otherwise), auto-detects the port (or `SERIAL_PORT=`), and connects at `SERIAL_BAUD` (default 115200). Exit with Ctrl-A X. |
| `make boot` | Drive the board to a Linux **login** over JTAG in one command: start OpenOCD, GDB-load U-Boot SPL → proper, then own the serial console to interrupt autoboot, set up networking, `tftp` the `fitImage`, and `bootm`. Collapses `make openocd` + `make gdb` + `make terminal`. Preflights its prereqs (`make image`; `make tftp`; `make tftp-ensure`; and for `BOOT_METHOD=nfs`, `make nfs-setup`) and names any that are missing. All knobs are `BOOT_*` / `BOARD_*` in `config.mk`. |
| `make publish GH_REPO=... GH_VERSION=...` | Stage a versioned, checksummed asset and upload a GitHub release (also TFTP-stages if `TFTP_DIR` is set). |
| `make new-app NAME=foo [KIND=...]` | Scaffold a new app skeleton under `src/apps/foo/`. |
| `make list-apps` | List the configured apps and their kinds. |
| `make list-serial-ports` | List present serial ports with their stable `/dev/serial/by-id/` names, USB chip + FTDI channel, and a tag on the FT4232H channel A (the JTAG channel — not the console). Use it to pick `SERIAL_PORT` for `make terminal`. |
| `make detect-console-port` | Find which serial port is the SC598 **console** by actively probing: it opens each USB-serial candidate, nudges it, and listens for output only the SOM console emits (U-Boot, `login:`, kernel banner, the `adsp-sc598` hostname). Board-agnostic (doesn't assume the bridge chip — this board's is a CP2102N) and definitive, but the **board must be powered and past the boot ROM** (in JTAG/no-boot the console is silent until `make boot`). Skips JTAG ports (ICE, FT4232H ch.A). Prints the detected `/dev/ttyUSBx` on stdout: `make terminal SERIAL_PORT="$(make -s detect-console-port)"`. |
| `make update-tooling` | Build the self-extracting tooling archive into `tooling/`. |
| `make clean` | Remove `src/<BUILDDIR>/tmp/` (keeps sstate). |
| `make distclean` | Also remove sstate-cache, downloads, the generated layer, and `tooling/`. |
| `make shell` | Drop into a subshell with the bitbake environment sourced. |
| `make distro-info` | Print the configured Yocto **distro name / version / codename** (e.g. *Analog Devices Inc Reference Distro (glibc) 5.0.1 (scarthgap)*), plus build context (MACHINE, TARGET_SYS, tune, SDK + bitbake versions) and the layer list — queried live from `bitbake -e`. |

Every variable can be overridden per invocation, e.g.
`make image MACHINE=adsp-sc594-som-ezkit IMAGE=adsp-sc5xx-minimal-mmc`.

---

## Configuration

All settings live in **`config.mk`** (heavily commented, with examples). Each
uses `?=`, so precedence is: **command line > environment > `config.mk`**.

| Variable | Default | Purpose |
|---|---|---|
| `BUILDDIR` | `build` | bitbake build subdir name under `src/`. |
| `MACHINE` | `adsp-sc598-som-ezkit` | Target board. Also valid: `adsp-sc598-som-ezlite`, `adsp-sc594-som-ezkit`, `adsp-sc594-som-ezlite`, `adsp-sc589-mini`, `adsp-sc573-ezkit`. |
| `DISTRO` | `adi-distro-glibc` | Distro policy (`adi-distro-musl` also available, with caveats). |
| `IMAGE` | `adi-sc5xx-custom` | Image recipe. The default is generated by `make apps`; stock options include `adsp-sc5xx-minimal-mmc`, `adsp-sc5xx-full`, `adsp-sc5xx-tiny`. |
| `SOM_REV` / `CRR_REV` | *(empty → BSP default)* | SoM / carrier-board hardware revision, written into `conf/local.conf` by `make configure`. Empty uses ADI's default (valid for SOM Rev A/B/C/D, EZ-Kit Carrier rev D); set (e.g. `SOM_REV=D`) only if your hardware differs. |
| `LINUX_MEM` | `224M` | RAM assigned to Linux; the SHARC+ cores get the rest of physical DDR (`DDR_SIZE − LINUX_MEM`). `make configure` validates it (`112M ≤ LINUX_MEM ≤ DDR_SIZE`) and the `meta-custom-bsp` kernel bbappend sets the device-tree `/memory` node + `mem=` from it. Also feeds `make boot` (`BOOT_MEM` derives from it). |
| `DDR_SIZE` / `DDR_BASE` | `512M` / `0x80000000` | Physical DDR on the SOM (board facts; confirm with `make board-info`). `LINUX_MEM` is bounded by `DDR_SIZE`. |
| `TFTP_DIR` | *(empty)* | TFTP server document root for `make tftp`. |
| `NFS_DIR` | *(empty)* | Host dir the rootfs is extracted into and exported over NFS (`make nfs-setup`). |
| `BOARD_IP` / `HOST_IP` | *(empty / auto)* | Board's static IP and this host's IP. **Shared** by `make boot` (U-Boot `ipaddr` / `serverip`) and the NFS-root `bootargs` (`ip=` / `nfsroot=`). `HOST_IP` auto-detects if empty. |
| `BOARD_NETMASK` / `BOARD_GATEWAY` / `BOARD_HOSTNAME` | `255.255.255.0` / *(empty)* / `sc598` | The remaining kernel `ip=` fields, shared by `make boot` and `make nfs-status`. |
| `NFS_ALLOW` / `NFS_VERS` / `NFS_SUDO` | `HOST_IP/24` / `3` / `sudo` | NFS export client spec, mount version, and the privilege prefix for `make nfs-setup`. |
| `SDK_VERSION` | `5.0.1` | ADI SDK version component of the install path (match your BSP release, cf. `REPO_MANIFEST_FILE`). |
| `SDK_IMAGE` | `$(IMAGE)` | Image whose SDK `make sdk` builds (`bitbake … -c populate_sdk`). |
| `SDK_INSTALL_DIR` | `/opt/<DISTRO>/<SDK_VERSION>` | Where `make sdk` installs the SDK; `make openocd` reads OpenOCD from here. |
| `SDK_SUDO` | *(empty)* | Prefix to run the SDK installer (set `sudo` when installing under `/opt`). |
| `OPENOCD_ICE` | `ice1000` | JTAG emulator config: `ice1000` or `ice2000`. |
| `OPENOCD_TARGET` | `adspsc59x_a55.cfg` | OpenOCD target config (SC598 Cortex-A55). |
| `OPENOCD_GDB_PORT` | `3333` | Port OpenOCD serves the GDB remote on. |
| `OPENOCD_SUDO` | *(empty)* | Prefix to elevate OpenOCD for ICE USB access (`sudo` when no udev rules). |
| `OPENOCD_BIN` / `_SCRIPTS` / `_SDK_ROOT` / `_EXTRA_ARGS` | derived from `SDK_INSTALL_DIR` | OpenOCD binary, scripts dir, SDK sysroot, and extra CLI args. |
| `GDB_BIN` / `GDB_ELF` / `GDB_HOST` | auto-found / *(empty)* / localhost | `make gdb`: the SDK aarch64 GDB (auto-found in the SDK), an optional U-Boot ELF to load, and the host running OpenOCD. |
| `RESET_MODE` | `halt` | `make reset-board` post-reset core state: `halt` (halted at the reset vector, ready for `make boot`), `run` (run from the BMODE boot source), or `init` (halt + reset-init events). |
| `SERIAL_PORT` / `SERIAL_BAUD` | auto-detect / `115200` | `make terminal` / `make boot`: serial console device (auto-detected/probed if empty) and baud rate. |
| `BOOT_METHOD` | `nfs` | `make boot` rootfs source: `nfs` (full systemd login via `make nfs-setup`) or `ramdisk` (the fitImage's initramfs → busybox shell). |
| `BOOT_FITIMAGE_ADDR` / `BOOT_FITIMAGE_NAME` | `0x90000000` / `fitImage` | DDR scratch the `fitImage` is tftp'd to (above `mem=224M`, so `bootm` isn't clobbered) and its TFTP filename. |
| `BOOT_CONSOLE` / `BOOT_EARLYCON` / `BOOT_MEM` | `ttySC0,115200` / `adi_uart,0x31003000` / `224M` | Kernel cmdline console / earlycon / mem the bootargs are built from (SC598 board facts). |
| `BOOT_SPL_SPIN_SYM` / `BOOT_SPL_RUN_SECS` / `BOOT_GDB_RESET` | `board_boot_order` / `4` / `1` | GDB two-stage load: the breakpoint that stops SPL post-DDR before loading proper (empty → timed interrupt after `RUN_SECS`); `monitor reset halt` first. |
| `BOOT_UBOOT_TIMEOUT` / `BOOT_LINUX_TIMEOUT` | `90` / `180` | Seconds to reach the U-Boot `=>` prompt, and to reach `login:` after `bootm`. |
| `BOOT_AUTO_LOGIN` / `BOOT_USER` / `BOOT_PASS` | *(empty)* / `root` / `adi` | If set, type these credentials at the login prompt. |
| `BOOT_INTERACTIVE` / `BOOT_AUTO_STAGE` | `1` / *(empty)* | After login, hand the console to minicom (set `0` for unattended); auto-run `make tftp` staging if the fitImage isn't staged. |
| `REPO_TOOL_URL` | Google Cloud Storage URL | Where to fetch the `repo` launcher binary (it is **Google's** tool, not ADI's). |
| `REPO_MANIFEST_URL` | `…/lnxdsp-repo-manifest.git` | The ADI manifest git repo (`repo init -u`). |
| `REPO_MANIFEST_BRANCH` | `main` | Manifest branch (`repo init -b`). |
| `REPO_MANIFEST_FILE` | `release-5.0.1.xml` | Manifest XML pinning the BSP release (`repo init -m`). |
| `GH_REPO` | *(empty, required for publish)* | `owner/repo` to publish releases to. |
| `GH_PROJECT` | `adsp-sc598` | Short label used in asset names / release titles. |
| `GH_VERSION` | *(empty, required for publish)* | Release tag — **strict SemVer 2.0.0, no `v` prefix**. |
| `GH_TARGET` | `main` | Git ref the release tag anchors to. |
| `GH_NOTES_FILE`, `GH_DRAFT`, `GH_PRERELEASE` | *(empty)* | Optional release-note file / draft / prerelease flags. |

---

## Example settings

[`config.mk.local`](config.mk.local) and [`README.local.md`](README.local.md) are
a committed **worked example**: the exact configuration and step-by-step commands
that took a fresh **ADSP-SC598-SOM Rev E** (Carrier Rev D) from an empty board to
a Linux login **over NFS** — U-Boot loaded via JTAG, kernel `fitImage` over TFTP,
root filesystem over NFS.

Unlike the machine-specific values in `config.mk` (left empty so a clone stays
generic), these two files carry concrete paths and IPs on purpose, as a template
to copy from. The settings used:

| Variable | Value | Why |
|---|---|---|
| `SOM_REV` / `CRR_REV` | `E` / `D` | SOM Rev E moves the console-enable GPIO to an ADP5588 @ i2c2 `0x34`; `E` builds the matching device tree — the fix that makes the serial console work (default `D` leaves it dead). |
| `TFTP_DIR` | `/mnt/nvme2n1/data02/tftp` | TFTP document root the board fetches `fitImage` from. |
| `SDK_INSTALL_DIR` | `/mnt/nvme2n1/data02/adi-sdk/<distro>/<ver>` | User-writable SDK path (host OpenOCD/GDB) — installs without sudo. |
| `NFS_DIR` | `/mnt/nvme2n1/data02/nfs/sc598-rootfs` | Host dir exported as the board's NFS root. |
| `BOARD_IP` / `HOST_IP` | `192.168.2.50` / `192.168.2.180` | Board's static IP and this host's IP for the `ip=` / `nfsroot=` bootargs. |

**Use case.** JTAG bring-up of a board whose OSPI/SD is empty: `make image`,
`make tftp`, `make nfs-setup`, then the three-terminal JTAG sequence (`make
openocd`, `make gdb`, `make terminal`) and a single `bootm` to a login —
iterating on the rootfs live over NFS, no reflash. `README.local.md` is the full
command-by-command runbook.

To apply the settings, copy them into your `config.mk`, or `-include
config.mk.local` from the `Makefile` (before `include config.mk`). Swap in your
own paths, IPs, and board revision.

---

## The custom-apps system

The headline feature. Instead of writing bitbake recipes, you describe each app
in `src/apps/<name>/app.yaml`; `bin/gen-apps.py` (run by `make apps`) reads every
manifest and emits a full `meta-custom-apps` layer:

- one recipe per app — `recipes-apps/<name>/<name>_<version>.bb`,
- `packagegroup-custom-apps` pulling them all in,
- the `adi-sc5xx-custom` image recipe (it `require`s the SD-card-capable
  `adsp-sc5xx-minimal-mmc` and installs the packagegroup).

### App kinds

| `kind` | Source of the app | Notes |
|---|---|---|
| `local-source` | hand-written code in `src/apps/<name>/src/` | built with `build.system` (`make`/`cmake`/`meson`/`autotools`/`none`). |
| `git` | a remote git repo (`git.url` + `git.rev`) | cloned by bitbake into the WORKDIR at build time. |
| `prebuilt-binary` | an ELF in `<name>/binary/` or a URL | installed as-is (strip/QA inhibited). |
| `prebuilt-tarball` | a tarball in `<name>/binary/` or a URL | unpacked, files installed per the manifest. |

### Manifest at a glance

```yaml
name: hello-world          # must equal the directory name
version: 0.1.0
summary: "Demo C program"
license: MIT               # needs a LICENSE/COPYING file (or 'CLOSED')
kind: local-source
build:
  system: make             # cmake | meson | autotools | make | none
  configure_args: []
install:
  bindir: [hello-world]    # also sbindir / libdir / custom: [{src,dst,mode}]
depends: []                # build-time DEPENDS
rdepends: []               # runtime RDEPENDS:${PN}
# optional: service: {unit, enable}, config: [{src,dst,mode}], files: [...],
#           users: [...]   # systemd unit, /etc config, extra files, useradd
```

**Full reference.** Every field, every kind, the build-system behaviour, and the
bitbake each option generates — with a complete annotated example — is documented
in **[`docs/app-yaml-reference.md`](docs/app-yaml-reference.md)**.

### Adding an app

```sh
make new-app NAME=sensor                 # KIND=local-source (default)
make new-app NAME=tool KIND=git          # or prebuilt-binary / prebuilt-tarball
# edit src/apps/<name>/app.yaml (and src/ for local-source), then:
make apps      # regenerate the layer
make image     # rebuild the image with the new app
make list-apps # see what's configured
```

`make new-app` scaffolds the directory (creating `src/apps/` on first use),
writes a starter `app.yaml`, and — for `local-source` — a buildable `src/` plus
a per-app `.gitignore` that ignores the in-tree build binary. Hand-written app
sources are version-controlled; build products are not (see
[Version control](#version-control)).

---

## Build configuration & overlays

`make configure` is idempotent. On first run it sources the ADI
`setup-environment` to create `src/<BUILDDIR>/conf/`, then **applies the overlay
fragments** between `# === BEGIN/END custom-apps overlay ===` markers (replacing
any previous block, so the build config always tracks `overlays/`):

- **`overlays/local.conf.fragment`** — enables the SD-card boot path
  (`ADSP_SC598_SDCARD = "1"`) and adds `debug-tweaks` (empty root password etc.;
  remove for production) plus `ssh-server-openssh` (guarantees the OpenSSH
  server is installed and `sshd` is enabled on boot).
- **`overlays/bblayers.conf.fragment`** — adds the generated `meta-custom-apps`
  and the static `meta-custom-bsp` layers to `BBLAYERS`.

When `SOM_REV` / `CRR_REV` are set, `make configure` also injects them into the
local.conf overlay block (`SOM_REV = "…"` / `CRR_REV = "…"`) — ADI's "select the
appropriate revision" step. Left empty, the BSP default applies (SOM Rev A/B/C/D,
EZ-Kit Carrier rev D).

`make configure` also resolves **`LINUX_MEM`** (the Linux ⇄ SHARC+ DDR split) into
the Linux DDR window and injects `LINUX_MEM` / `LINUX_MEM_BASE` / `LINUX_MEM_SIZE`
into the same block. The `meta-custom-bsp` bbappends read those and set **U-Boot's
`CFG_SYS_SDRAM_BASE/SIZE`** (`u-boot-adi`) and the kernel **device-tree `/memory`
node + `mem=` bootarg** (`linux-adi`) from them — U-Boot's `bootm` rewrites the
kernel `/memory` node from `CFG_SYS_SDRAM_*` (`arch_fixup_fdt`), so both are set
and kept in agreement. Linux occupies the **top** of physical DDR and the SHARC+
cores get the remainder at the bottom; it's validated `112M ≤ LINUX_MEM ≤
DDR_SIZE` (the floor exists because the FIT loads the kernel DTB at `0x99000000`,
which must sit inside Linux's window). Changing `LINUX_MEM` rebuilds U-Boot + the
kernel DTB. See the `LINUX_MEM` block in `config.mk` for the address layout.

To reset the build config, delete the marked block(s) and re-run `make
configure`, or `make distclean` and rebuild.

---

## Booting the board

### Serial console
`make terminal` opens a **minicom** session on the board's USB/UART — where you
watch U-Boot and Linux boot, and "Terminal1" alongside `make openocd` / `make
gdb`. It checks minicom is installed (and tells you how to install it otherwise),
auto-detects the serial port (or set `SERIAL_PORT=/dev/ttyUSBx` — see `make
list-serial-ports`), and opens it at `SERIAL_BAUD` (default 115200, 8N1) via
`minicom -D <port> -b <baud> -o`. Exit minicom with **Ctrl-A** then **X**. Serial
access needs `dialout` membership (`sudo usermod -aG dialout $USER`, then re-login)
or `make terminal TERMINAL_SUDO=sudo`.

**Which port?** With several USB-serial adapters attached, `make list-serial-ports`
shows each port's stable `/dev/serial/by-id/` name, USB chip and FTDI channel, and
tags the FT4232H's **channel A** — the JTAG channel `make openocd` drives, which is
*never* the console. The SC598 console is one of the FT4232H's other UART channels
(ch.B/C/D); confirm by watching for boot output, then pin it with the stable name —
`make terminal SERIAL_PORT=/dev/serial/by-id/usb-FTDI_…-if0N-port0` (immune to
`ttyUSB` renumbering across reboots/replug).

### SD card
`make image` produces a `wic.gz`; `make sdcard` decompresses it to
`images/sdcard.img`; `make flash DEV=/dev/sdX` writes it. The flasher refuses any
device whose partitions are mounted on `/`, `/boot`, `/home`, `/usr`, or `/var`,
shows you `lsblk` for the target, requires you to type `YES`, unmounts the
device, then `sudo dd … conv=fsync`.

### TFTP / network boot
`make tftp TFTP_DIR=/srv/tftp/sc598` stages the canonical ADI `fitImage` (a
single signed kernel+dtb+ramdisk bundle) plus discrete `Image.gz`,
`<board>.dtb`, and the ramdisk `cpio.gz`, and writes a `README.tftp-boot` with
copy-paste u-boot commands, e.g.:

```text
=> tftpboot 0x80000000 fitImage
=> bootm 0x80000000
```

`make tftp-status` tells you whether a TFTP daemon is actually running, the
address:port it listens on, which directory it serves, and its config file path
— and, with `TFTP_DIR` set, warns when the server serves a *different* directory
than you staged into (the classic "staged files the board never sees" failure). `make tftp-ensure` starts an installed-but-stopped daemon
(tftpd-hpa, atftpd, or a tftp-enabled dnsmasq) via `sudo`; it never auto-installs
a package nor silently rewrites a server's config.

`make tftp-test` proves the path end-to-end: it lists what's in the served
directory (a filesystem view — TFTP has no directory-listing opcode, so there is
no over-the-wire `ls`) and then actually fetches the smallest file over TFTP from
loopback, byte-comparing it against the on-disk source. Target a specific file
with `TFTP_TEST_FILE=fitImage`, or a non-loopback server with `TFTP_TEST_HOST=<ip>`.

### NFS root (development)
For fast iteration, boot the board against a rootfs that lives on this host over
NFS — edit files, reboot, changes are live, no reflash. `make nfs-setup` (root,
via `NFS_SUDO`) installs `nfs-kernel-server`, extracts the built `…rootfs.tar.xz`
into `NFS_DIR`, and exports it to your subnet with `no_root_squash`;
`make nfs-status` reports whether the export is live and prints the exact U-Boot
commands (filled in from `BOARD_IP` / `HOST_IP` / `NFS_DIR`):

```text
=> setenv bootargs console=ttySC0,115200 earlycon=adi_uart,0x31003000 mem=224M ip=<board>:<host>::255.255.255.0:sc598:eth0:off nfsroot=<host>:<NFS_DIR>,nfsvers=3,tcp
=> tftp 0x90000000 fitImage
=> bootm 0x90000000
```

There is **no `root=`**: ADI's initramfs greps `nfsroot=` first, mounts it, and
`switch_root`s in; the kernel's `ip=` brings up `eth0` before the mount (needs
`CONFIG_IP_PNP`, which the ADI kernel sets). Omit `nfsroot=` (and `root=`)
entirely and the same initramfs instead drops to a getty on the console — a
RAM-only shell from the fitImage's bundled ramdisk, handy for a first boot.

### JTAG debug (OpenOCD)
`make openocd` launches the ADI fork of OpenOCD over an ICE-1000/ICE-2000 JTAG
emulator, reproducing the getting-started guide's "Terminal2" step:

```text
openocd -f .../interface/ice1000.cfg -f .../target/adspsc59x_a55.cfg
```

OpenOCD and its `.cfg` scripts come from the **ADI SDK** (not the target image),
which you build + install once with **`make sdk`** (into `SDK_INSTALL_DIR`,
default `/opt/<DISTRO>/<SDK_VERSION>`; `SDK_SUDO=sudo` to write `/opt`). With
OpenOCD running, **`make gdb`** in a second terminal attaches the SDK's aarch64
GDB to `:3333` (`target extended-remote :3333`), auto-loading
`u-boot-spl-<board>.elf` from the deploy dir (or `GDB_ELF`) so you can `load` it
into RAM and `c`. Everything is parameterised in `config.mk` — `OPENOCD_ICE`
(ice1000/ice2000), `OPENOCD_BIN`, `OPENOCD_SCRIPTS`, `OPENOCD_TARGET`,
`OPENOCD_GDB_PORT`, `OPENOCD_SUDO`, `SDK_VERSION`, and the `GDB_*` vars. The ICE
is a libusb device, so without udev rules you'll need `OPENOCD_SUDO=sudo`.

**`make board-info`** probes the board in one shot without GDB: it runs OpenOCD
as a batch (init → query → shutdown) and prints the JTAG scan chain (TAP IDCODEs
— the ADI JTAG controller `0x0282e0cb` and CoreSight DAP `0x4ba06477`), the
CoreSight ROM table, the targets and Cortex-A55 registers, and SC598
memory-mapped ID/status registers — silicon revision (`CDU0_REVID`), boot mode
(`RCU_STAT` BMODE → JTAG/QSPI/UART/OSPI/eMMC), the DDR controllers, and a decoded
**RAM map** — it probes each DDR controller (DMC0, DMC1), decodes the SDRAM
geometry from every populated one, and reports each bank's base + size plus the
total (e.g. one bank: `0x80000000`, 512 MB). An absent controller bus-faults
harmlessly: the probe lowers the log level around the read (to hide the expected
`JTAG-DP STICKY ERROR`) and clears the DP sticky bit so the resume stays safe. It
needs the adapter to itself, so don't run it while `make openocd` holds the link.

### Reset the board over JTAG (`make reset-board`)
`make reset-board` resets the SC598 over the ICE in one shot — a self-contained
OpenOCD batch (`init` → `reset` → `shutdown`) like `make board-info`, so it does
**not** hold the adapter (don't run it while `make openocd` is up). The SC598
target cfg declares `reset_config trst_only` — the ICE has **no SRST line** — so
`reset` runs the cfg's on-chip **RCU + CTI warm system reset**.

**Limitation (verified on hardware).** A core that is already running an OS — e.g.
Linux from a previous `make boot` — **cannot** be reset this way. OpenOCD halts
it, but ADI's RCU/CTI sequence then *aborts* (`abort occurred` / `Error executing
event reset-assert`); the core is **not** reset and resumes the OS. With no SRST
to force it, the only reset in that state is a **power-cycle** (BMODE in
JTAG/no-boot) — the same thing `make boot` asks for. `make reset-board` detects
the abort and reports `COULD NOT RESET` rather than claiming success. The reset
*does* complete on a core that is not deep in an OS (the boot ROM, U-Boot/SPL, or
bare metal), where the sequence ends with `system reset done`.

`RESET_MODE` picks the post-reset state when the reset completes: `halt` (default)
leaves the A55 halted at the reset vector; `run` runs from the BMODE boot source
(in JTAG/no-boot BMODE the boot ROM just spins; in QSPI/eMMC/SD BMODE it boots
U-Boot → Linux); `init` is `halt` plus any OpenOCD reset-init events.

### Automated boot to Linux (`make boot`)
`make boot` collapses the whole three-terminal JTAG bring-up into one hands-free
command that ends at a Linux `login:` prompt. It drives, in order:

1. **OpenOCD** — started over the ICE (or an already-running one on
   `OPENOCD_GDB_PORT` is reused).
2. **GDB**, two-stage, the way the SC598 needs in JTAG/no-boot mode: `load` U-Boot
   **SPL** and run it (it inits DDR, then spins waiting for proper at
   `board_boot_order`); stop there, `load` U-Boot **proper** and run it. Proper's
   `board_init_r` probes the **ADP5588 @ i2c2 `0x34`** and asserts `uart0-en` —
   which is what brings the Rev-E console to life.
3. **Serial console** — `make boot` owns it (auto-probing the USB-serial ports and
   locking onto whichever emits the U-Boot banner, unless `SERIAL_PORT` pins it),
   interrupts autoboot, sets up networking, **ping-gates** the link, `tftp`'s the
   `fitImage` into DDR (`BOOT_FITIMAGE_ADDR`, default `0x90000000`), and `bootm`'s.
4. **Login** — on `BOOT_METHOD=nfs` (default) the board NFS-mounts the rootfs
   `make nfs-setup` exported and reaches a full systemd `login:`; `BOOT_METHOD=ramdisk`
   stops at the fitImage's initramfs busybox shell instead. By default the live
   console is then handed to minicom so you can log in (`root` / `adi`); set
   `BOOT_INTERACTIVE=0` for unattended use.

The U-Boot command sequence is built by the same emitter `make nfs-status` uses
(`bin/lib/bootcmds.sh`), so the two never diverge, and it's written to
`images/boot-cmds.txt` for inspection. The whole session is logged to
`images/boot.log`.

**Prerequisites** (preflighted — each missing one is reported with the fix):

```text
make image          # the fitImage + U-Boot ELFs + rootfs
make tftp           # stage the fitImage into TFTP_DIR
make tftp-ensure    # start the TFTP server (sudo)
make nfs-setup      # export the rootfs (sudo) — only for BOOT_METHOD=nfs
make boot           # … then drive it all to a login
```

> **The board must be in a fresh JTAG state for each run** — BMODE in the
> JTAG/no-boot position, freshly power-cycled. `make boot` resets the SoC over the
> ICE to load SPL, and the ICE **cannot reset a running core**, so re-running while
> Linux is still up from a previous boot fails the GDB attach. `make boot` detects
> that and tells you to power-cycle rather than failing cryptically — power-cycle,
> then run again. (`make reset-board` can't substitute here — ADI's reset aborts
> on a running core.)

Because OpenOCD needs the ICE over USB, `make boot` runs it under `OPENOCD_SUDO`
(default `sudo`) — expect a password prompt unless you've installed udev rules.
All timings, addresses, the spin-symbol breakpoint, login credentials, and the
interactive handoff are `BOOT_*` variables in `config.mk`.

---

## Publishing releases

`make publish GH_REPO=you/repo GH_VERSION=1.2.3` uses the `gh` CLI to attach the
built `wic.gz` (preferred over the larger raw `.img`) to a GitHub release, with a
SHA-256 sidecar and an auto-generated note (machine, image, size, checksum,
flashing command). `GH_VERSION` is validated against the **full Semantic
Versioning 2.0.0 grammar** — the `v` prefix and malformed versions are rejected
before anything is uploaded. Re-publishing the same tag re-uploads assets with
`--clobber`. If `TFTP_DIR` is set, `make publish` also TFTP-stages.

---

## Software Bill of Materials (SBOM)

Two SBOMs, for two different things:

**Harness SBOM — `sbom.spdx.jsonld` (committed).** An SPDX 3.0.1 document in
JSON-LD describing *this repository* (the harness plus the `hello-world` example)
and the external build/runtime tools it depends on. It carries the NTIA minimum
elements and validates clean against the official SPDX 3.0.1 SHACL shapes (e.g.
`pyshacl` against `https://spdx.org/rdf/3.0.1/spdx-model.ttl`, run without RDFS
inference).

**Product SBOM — generated by the build.** `overlays/local.conf.fragment` enables
Yocto's `create-spdx` class, so the build emits an SPDX SBOM for the *firmware
image* and every recipe/package in it — this is the SBOM that matters for the
shipped product (CRA / EO 14028). Note: this poky (scarthgap) ships **SPDX 2.2**
only (JSON, not 3.0/JSON-LD) — still ISO/IEC 5962:2021 + NTIA-conformant.

- `make sbom` (re)generates it (incremental bitbake) and copies it into `images/`.
- `make image` collects it automatically as well.
- Raw output lands under `src/<BUILDDIR>/tmp/deploy/`:
  `images/<MACHINE>/<IMAGE>-<MACHINE>.spdx.tar.zst` (image + all sub-documents)
  and `spdx/recipes/`, `spdx/packages/` (per recipe / per package).

The product SBOM copied into `images/` is git-ignored (a per-build artifact); the
harness SBOM at the repo root is committed.

---

## Packaging the tooling

`make update-tooling` runs `bin/make-tooling-archive.sh`, which bundles the
harness (`Makefile`, `config.mk`, `bin/`, `overlays/`, `src/apps/`) — **not** the
multi-gig BSP — into a self-extracting `tooling/adsp-sc598-tooling.sh`. It is a
POSIX `/bin/sh` script with a gzip payload and an embedded SHA-256:

```sh
sh adsp-sc598-tooling.sh --list      # show contents
sh adsp-sc598-tooling.sh --check     # verify integrity
sh adsp-sc598-tooling.sh -C /dest    # extract (refuses to clobber without -f)
```

The bundle is self-reproducing: the extracted copy can rebuild its own archive.

---

## Troubleshooting

**`make image` / `make apps` dies with a permission error on a generated file**
— e.g. `Permission denied: LICENSE` somewhere under
`src/layers/meta-custom-apps/`. The generated layer was created by an earlier run
as **root** - almost always a stray `sudo make ...` - leaving root-owned files
your normal user can no longer regenerate (the next, non-root run cannot delete
them). The tooling now refuses to run as root up front, but to clear debris left
by an earlier run, delete the generated layer (it is regenerated from
`src/apps/`, so nothing is lost) and re-run **without** sudo:

```bash
sudo rm -rf src/layers/meta-custom-apps   # regenerated by the next `make apps`
make image
```

Never run the build as root: `bin/gen-apps.py`, `bin/configure-build.sh`, and
bitbake itself all refuse `uid 0`. A deliberate all-root container build can
override the harness guards with `ADSP_ALLOW_ROOT=1`.

**`make openocd` fails with `LIBUSB_ERROR_ACCESS` / "cannot connect to ICE-1000
emulator"** — OpenOCD found the JTAG adapter but your user can't open its USB
device. On the SC598-SOM-EZKIT the debug interface is an on-board FTDI
**FT4232H** (`0403:6011`). This repo defaults `OPENOCD_SUDO=sudo`, so
`make openocd` runs elevated and works out of the box. For least privilege (no
sudo, no root-owned OpenOCD server), install a udev rule granting access and
replug the debug cable:

```bash
echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6011", MODE="0666"' \
  | sudo tee /etc/udev/rules.d/99-adi-ice1000.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then set `OPENOCD_SUDO=` (empty). `MODE="0666"` also works over SSH; for a tighter
rule use `MODE="0660", GROUP="plugdev"` and add yourself to `plugdev`. If the
error then becomes `LIBUSB_ERROR_BUSY`, the `ftdi_sio` kernel driver has claimed
the channel — OpenOCD normally auto-detaches it, otherwise unbind that interface.

---

## Version control

`git init && git add -A` captures exactly the harness — `Makefile`, `config.mk`,
`bin/`, `overlays/`, and your `src/apps/` sources — and nothing else. The
`.gitignore` ignores everything under `src/` except `src/apps/` (the fetched BSP,
`repo` metadata, generated layer, and bitbake build tree), plus `images/` and
`tooling/` outputs. In-tree app build artifacts are ignored; hand-written
sources and committed prebuilt binaries are kept.

---

## License

This project - the build harness (`Makefile`, `config.mk`, `bin/`, `overlays/`,
and the example app under `src/apps/`) - is licensed under the **MIT License**;
see [`LICENSE.md`](LICENSE.md). The software it **builds** (Linux, u-boot, poky,
`meta-adi`, and the rest of the BSP) carries its own upstream licenses, which
bitbake surfaces in the image's license manifest under the deploy directory.

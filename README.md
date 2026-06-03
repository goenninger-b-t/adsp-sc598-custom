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
├── README.md                      # this file
├── bin/                           # automation scripts the Makefile calls
│   ├── repo-init.sh               #   make init           — fetch `repo`, repo init
│   ├── configure-build.sh         #   make configure      — build dir + overlays
│   ├── gen-apps.py                #   make apps/new-app/list-apps — app layer generator
│   ├── flash-sdcard.sh            #   make flash          — guarded dd to SD card
│   ├── tftp-stage.sh              #   make tftp           — net-boot artifact staging
│   ├── publish-release.sh         #   make publish        — GitHub release upload
│   ├── list-serial-ports.sh       #   make list-serial-port — present serial ports
│   └── make-tooling-archive.sh    #   make update-tooling — self-extracting archive
├── overlays/                      # bitbake conf fragments applied to the build dir
│   ├── local.conf.fragment        #   SD-card boot path + debug-tweaks
│   └── bblayers.conf.fragment     #   adds the generated meta-custom-apps layer
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

Only `Makefile`, `config.mk`, `bin/`, `overlays/`, and `src/apps/` are tracked
in git. Everything else is re-creatable from the targets above.

---

## Prerequisites

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
  (tftpd-hpa / dnsmasq) for `make tftp`; `sudo` for `make flash`.

> The harness does **not** vendor the BSP. `make init`/`make fetch` pull it from
> Analog Devices' GitHub (and `repo` from Google) at first run.

---

## Quick start

```sh
# 1. Bootstrap the BSP (first run only; make fetch will also init if needed)
make init
make fetch

# 2. Build the default custom image for the default machine
make image                       # = configure + apps + bitbake adi-sc5xx-custom

# 3a. Boot from SD card
make sdcard                      # images/sdcard.img
make flash DEV=/dev/sdX          # guarded; type YES to confirm

# 3b. …or boot over the network
make tftp TFTP_DIR=/srv/tftp/sc598

# 4. (optional) publish the image as a GitHub release
make publish GH_REPO=you/sc598-images GH_VERSION=1.0.0
```

Run `make` with no arguments (or `make help`) for the full target list and the
current settings.

---

## Make targets

| Target | What it does |
|---|---|
| `make init` | Download the `repo` launcher (`REPO_TOOL_URL`) to `src/bin/repo`, then `repo init` against the ADI manifest. Creates `src/.repo/`. |
| `make fetch` | `repo sync` the BSP into `src/sources/`. Auto-runs `init` first if `src/.repo` is missing. |
| `make configure` | Initialise the bitbake build dir (`src/<BUILDDIR>`) and idempotently apply `overlays/` to `local.conf`/`bblayers.conf`. Requires `make fetch` first. |
| `make apps` | (Re)generate `src/layers/meta-custom-apps` from every `src/apps/<name>/app.yaml`. |
| `make image [IMAGE=name]` | `configure` + `apps` + `bitbake` the image, then copy the `wic.gz` into `images/`. |
| `make sdcard` | Decompress the `wic.gz` to `images/sdcard.img`. |
| `make flash DEV=/dev/sdX` | `dd` `images/sdcard.img` to the device, with mount-point safety checks and a typed `YES` confirmation. |
| `make tftp TFTP_DIR=...` | Stage `fitImage` / kernel / dtb / initrd into a TFTP root and write a `README.tftp-boot` with u-boot commands. |
| `make publish GH_REPO=... GH_VERSION=...` | Stage a versioned, checksummed asset and upload a GitHub release (also TFTP-stages if `TFTP_DIR` is set). |
| `make new-app NAME=foo [KIND=...]` | Scaffold a new app skeleton under `src/apps/foo/`. |
| `make list-apps` | List the configured apps and their kinds. |
| `make list-serial-port` | List host serial ports that are backed by real hardware. |
| `make update-tooling` | Build the self-extracting tooling archive into `tooling/`. |
| `make clean` | Remove `src/<BUILDDIR>/tmp/` (keeps sstate). |
| `make distclean` | Also remove sstate-cache, downloads, the generated layer, and `tooling/`. |
| `make shell` | Drop into a subshell with the bitbake environment sourced. |

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
| `TFTP_DIR` | *(empty)* | TFTP server document root for `make tftp`. |
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
  remove for production).
- **`overlays/bblayers.conf.fragment`** — adds `meta-custom-apps` to `BBLAYERS`.

To reset the build config, delete the marked block(s) and re-run `make
configure`, or `make distclean` and rebuild.

---

## Booting the board

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

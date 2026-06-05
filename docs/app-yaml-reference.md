# `app.yaml` reference — the custom-apps manifest

Every directory under `src/apps/<name>/` that contains an `app.yaml` is turned
into a complete Yocto recipe by `bin/gen-apps.py` (run by `make apps`, and
automatically by `make image`). You never write a `.bb` — you describe the app
declaratively in `app.yaml` and the generator emits the recipe, wires it into a
packagegroup, and adds it to the custom image.

This document explains **every** `app.yaml` field by example. It is the
authoritative companion to `bin/gen-apps.py`; if the two ever disagree, the code
wins (and the doc is a bug).

- [Workflow](#workflow)
- [App directory layout](#app-directory-layout)
- [The four kinds](#the-four-kinds)
- [Complete annotated example](#complete-annotated-example)
- [Field reference](#field-reference)
- [Kind-specific blocks](#kind-specific-blocks)
- [Build systems & the install map](#build-systems--the-install-map)
- [Path semantics (read this)](#path-semantics-read-this)
- [What gets generated](#what-gets-generated)
- [Validation rules & gotchas](#validation-rules--gotchas)

---

## Workflow

```sh
make new-app NAME=sensor-daemon          # scaffold src/apps/sensor-daemon/
# …edit src/apps/sensor-daemon/app.yaml (and src/ for local-source)…
make apps                                # (re)generate the meta-custom-apps layer
make list-apps                           # see what's configured
make image                               # build an image that installs your app
```

`make apps` reads every `src/apps/*/app.yaml`, validates it, and **fully
regenerates** `src/layers/meta-custom-apps/`. That layer is disposable — never
edit it by hand; edit `app.yaml` and re-run `make apps`.

---

## App directory layout

A fully-featured app directory looks like this. Only `app.yaml` is always
required; the rest depends on which fields you use.

```
src/apps/sensor-daemon/
├── app.yaml                       # the manifest (required)
├── LICENSE                        # required unless license: CLOSED
│                                  #   (also accepted: LICENSE.txt, COPYING, COPYING.md)
├── src/                           # required for kind: local-source — your buildable source
│   ├── Makefile
│   └── sensor-daemon.c
├── config/
│   └── sensor.conf                # referenced by  config[].src
├── data/
│   └── calibration.bin            # referenced by  files[].src
├── service/
│   └── sensor-daemon.service      # referenced by  service.unit
└── binary/                        # for kind: prebuilt-* with a file:// url
    └── sensor-daemon              #   the ELF or tarball you ship
```

When source is staged into the build, the generator strips VCS/editor cruft
(`.gitignore`, `.git/`, `.gitattributes`, `*.swp`) so it never reaches the
bitbake `WORKDIR`.

---

## The four kinds

`kind` selects where the app's payload comes from:

| `kind` | Payload | Needs | Built? |
|---|---|---|---|
| `local-source` | hand-written code in `<app>/src/` | `build.system`, a `src/` dir | yes — by `build.system` |
| `git` | a remote git repo | `git.url`, `git.rev`, `build.system` | yes — by `build.system` |
| `prebuilt-binary` | a ready ELF (local file or URL) | `binary.url` | no — installed as-is |
| `prebuilt-tarball` | a ready tarball (local file or URL) | `binary.url` | no — unpacked & installed |

The **identity** fields (`name`/`version`/`summary`/`license`) and the
**cross-cutting** fields (`depends`, `rdepends`, `config`, `files`, `service`,
`users`) apply to *all four* kinds. Only `build` / `git` / `binary` and the
`install` map are kind-specific (see [Build systems & the install
map](#build-systems--the-install-map)).

---

## Complete annotated example

A `local-source` + `make` app exercising **every** cross-cutting option. (The
`git` and `prebuilt-*` source blocks are shown [below](#kind-specific-blocks).)

```yaml
# ── Identity — all four are REQUIRED ──────────────────────────────────────
name: sensor-daemon          # MUST equal the directory name (src/apps/sensor-daemon/).
                             #   grammar: ^[a-z][a-z0-9-]*$   →  becomes the recipe PN
version: "1.2.0"             # grammar: ^[A-Za-z0-9.+~_-]+$   →  recipe PV
                             #   →  emits sensor-daemon_1.2.0.bb  (use "git" for live git)
summary: "Reads the on-board sensor and publishes readings"   #  →  SUMMARY
license: MIT                 # an SPDX identifier, OR  CLOSED  for proprietary/internal.
                             #   non-CLOSED REQUIRES a LICENSE/COPYING file in the app dir
                             #   (it is staged and md5-pinned into LIC_FILES_CHKSUM).

# ── Where the app comes from ──────────────────────────────────────────────
kind: local-source           # local-source | git | prebuilt-binary | prebuilt-tarball

# ── How to build it — REQUIRED for local-source and git ───────────────────
build:
  system: make               # make | cmake | meson | autotools | none
  configure_args: []         # extra configure flags →  EXTRA_OECMAKE / EXTRA_OEMESON /
                             #   EXTRA_OECONF.  (cmake/meson/autotools only; ignored by make/none)

# ── What to install, and where — the "install map" ────────────────────────
# Paths are relative to the BUILD output dir S. Honoured for make / none /
# prebuilt-* kinds; IGNORED for cmake/meson/autotools (their own install runs).
install:
  bindir:  [sensor-daemon]              #  →  /usr/bin/sensor-daemon   (mode 0755)
  sbindir: [sensor-admin]               #  →  /usr/sbin/sensor-admin   (mode 0755)
  libdir:  [libsensor.so.1]             #  →  /usr/lib/libsensor.so.1  (mode 0644)
  custom:                               # anything → any absolute path
    - src: share/profiles.db            #   relative to S (the build output)
      dst: /usr/share/sensor/profiles.db
      mode: "0644"                      #   default 0644  (QUOTE it — see gotchas)

# ── Dependencies ──────────────────────────────────────────────────────────
depends:  [zlib, libgpiod]              # build-time   →  DEPENDS
rdepends: [bash]                        # runtime      →  RDEPENDS:${PN}

# ── Config files — preserved across package upgrades (CONFFILES) ──────────
# src is relative to the APP dir (src/apps/sensor-daemon/); dst is absolute.
config:
  - src: config/sensor.conf
    dst: /etc/sensor/sensor.conf
    mode: "0644"                        # default 0644

# ── Arbitrary extra files — staged & installed, but NOT marked as config ──
files:
  - src: data/calibration.bin           # relative to the APP dir
    dst: /usr/share/sensor/calibration.bin
    mode: "0444"

# ── systemd service ───────────────────────────────────────────────────────
service:
  unit: service/sensor-daemon.service   # relative to the APP dir; a real .service file
  enable: true                          # default true  →  SYSTEMD_AUTO_ENABLE = "enable"

# ── Runtime user(s)/group(s) via useradd ──────────────────────────────────
users:
  - name: sensor                        # the only required key
    system: true                        # default true   →  -r --system
    shell: /sbin/nologin                # default /sbin/nologin
    home: /var/lib/sensor               # default /nonexistent
```

---

## Field reference

### Identity (all required)

| Field | Type | Notes |
|---|---|---|
| `name` | string | `^[a-z][a-z0-9-]*$`, and **must equal the directory name**. Becomes the recipe `PN`. |
| `version` | string | `^[A-Za-z0-9.+~_-]+$`. Becomes `PV` → recipe file `<name>_<version>.bb`. Use `"git"` for an autorev git app. |
| `summary` | string | One-line description → `SUMMARY`. |
| `license` | string | An SPDX id (`MIT`, `GPL-2.0-only`, `BSD-3-Clause`, …) → `LICENSE`, **or** `CLOSED` for proprietary code. Non-`CLOSED` requires a `LICENSE` / `LICENSE.txt` / `COPYING` / `COPYING.md` file in the app dir, which is staged and pinned via `LIC_FILES_CHKSUM` (md5). |

### Dependencies (optional, all kinds)

| Field | Type | Default | Effect |
|---|---|---|---|
| `depends` | list of strings | `[]` | Build-time deps → `DEPENDS`. |
| `rdepends` | list of strings | `[]` | Runtime deps → `RDEPENDS:${PN}`. |

### `install` — the install map (optional)

Emitted as an explicit `do_install` for `make` / `none` / `prebuilt-*` (see
[Build systems](#build-systems--the-install-map)).

| Field | Type | Installs to | Mode |
|---|---|---|---|
| `install.bindir` | list of paths (rel. `S`) | `${bindir}` (`/usr/bin`) | `0755` |
| `install.sbindir` | list of paths (rel. `S`) | `${sbindir}` (`/usr/sbin`) | `0755` |
| `install.libdir` | list of paths (rel. `S`) | `${libdir}` (`/usr/lib`) | `0644` |
| `install.custom` | list of `{src, dst, mode}` | `dst` (absolute) | `mode` (default `0644`) |

`install.custom[]` entries require `src` (relative to `S`) and `dst` (absolute);
each `dst` is added to `FILES:${PN}`.

### `config` — config files (optional, all kinds)

List of `{src, dst, mode}`. `src` is relative to the **app dir**; `dst` is
absolute; `mode` defaults to `0644`. Each file is staged via `SRC_URI`, installed
in a `do_install:append`, and registered in **both** `CONFFILES:${PN}` (so it is
preserved across package upgrades) and `FILES:${PN}`.

### `files` — arbitrary extra files (optional, all kinds)

Identical to `config` (`{src, dst, mode}`, `src` relative to the app dir) **but
not** marked as `CONFFILES` — added to `FILES:${PN}` only. Use for data files,
firmware, scripts, etc. that aren't user-editable config.

### `service` — systemd unit (optional, all kinds)

| Field | Type | Default | Effect |
|---|---|---|---|
| `service.unit` | path (rel. app dir) | — | The `.service` file to install. Triggers `inherit systemd`, installs to `${systemd_system_unitdir}`, sets `SYSTEMD_SERVICE:${PN}`. |
| `service.enable` | bool | `true` | `SYSTEMD_AUTO_ENABLE` = `enable`/`disable` — whether it starts on boot. |

### `users` — runtime users/groups (optional, all kinds)

List of user objects → `inherit useradd` + `USERADD_PARAM:${PN}`.

| Field | Type | Default | Maps to |
|---|---|---|---|
| `name` | string | — (required) | the username |
| `system` | bool | `true` | `--system` (plus `-r`) |
| `shell` | string | `/sbin/nologin` | `-s <shell>` |
| `home` | string | `/nonexistent` | `-d <home>` |

---

## Kind-specific blocks

Swap the `kind` + source block; the identity and cross-cutting fields are the
same as the [complete example](#complete-annotated-example).

### `git`

```yaml
kind: git
git:
  url: https://github.com/example/sensor-daemon.git   # https/http → protocol=https/http;
                                                      #   git@…/ssh://… → protocol=ssh
  rev: 9f3a1c2d4e5f60718293a4b5c6d7e8f901234567       # full SRCREV (a commit SHA)
  branch: main                                        # optional, default "main"
build:
  system: cmake                                       # built like any local-source
  configure_args: ["-DENABLE_FOO=ON"]
```

### `prebuilt-binary`

```yaml
kind: prebuilt-binary
binary:
  url: "file://binary/sensor-daemon"     # file:// is relative to the app dir; sha256 auto-computed.
  # url: "https://host/sensor-daemon"    # remote → sha256 below is REQUIRED
  # sha256: "<64 hex chars>"
install:
  custom:
    - src: sensor-daemon                 # relative to S (= WORKDIR for prebuilt)
      dst: /usr/bin/sensor-daemon
      mode: "0755"
```

### `prebuilt-tarball`

```yaml
kind: prebuilt-tarball
binary:
  url: "file://binary/sensor-daemon.tar.gz"   # unpacked into S; sha256 auto for file://
install:
  custom:
    - src: bin/sensor-daemon                  # path *inside* the tarball, relative to S
      dst: /usr/bin/sensor-daemon
      mode: "0755"
```

Prebuilt recipes are emitted with `INHIBIT_PACKAGE_STRIP`, `INHIBIT_SYSROOT_STRIP`
and `INSANE_SKIP:${PN} += "already-stripped ldflags file-rdeps arch"` so a
pre-built, pre-stripped, possibly foreign-built binary passes Yocto QA.

### `binary` reference

| Field | Required | Notes |
|---|---|---|
| `binary.url` | yes | `file://<rel-path>` (relative to the app dir), or `http(s)://` / `ftp://`. |
| `binary.sha256` | for remote URLs | Auto-computed for `file://`; **required** for `http(s)`/`ftp`. |

### `git` reference

| Field | Required | Notes |
|---|---|---|
| `git.url` | yes | `https`/`http`/`git@`/`ssh://`/other; the protocol is derived from the scheme. |
| `git.rev` | yes | Pinned `SRCREV` (full commit SHA — don't use a tag/branch name). |
| `git.branch` | no | Default `main`. |

---

## Build systems & the install map

`build.system` (local-source / git only) decides how the app is compiled **and**
whether the `install` map is used:

| `build.system` | Compile | Install | `install` map | `configure_args` → |
|---|---|---|---|---|
| `cmake` | `inherit cmake` | the project's `install()` rules | **ignored** | `EXTRA_OECMAKE` |
| `meson` | `inherit meson pkgconfig` | the project's install | **ignored** | `EXTRA_OEMESON` |
| `autotools` | `inherit autotools` | `make install` (autotools) | **ignored** | `EXTRA_OECONF` |
| `make` | `oe_runmake` (passes `CC/CXX/LD/AR/*FLAGS`) | the install map, **or** `make install DESTDIR=… PREFIX=/usr` if the map is empty | **used** | — |
| `none` | nothing | the install map | **used** | — |
| *(prebuilt-\*)* | nothing | the install map | **used** | — |

**Key consequence:** for `cmake` / `meson` / `autotools`, installation comes from
the upstream project's own install rules — the `install:` map is **not applied**
(and putting entries in `install.custom` there would add to `FILES:${PN}` without
installing anything, breaking packaging). Use the install map with `make`,
`none`, and the `prebuilt-*` kinds. The cross-cutting `config` / `files` /
`service` / `users` blocks work with *every* build system (they are appended on
top of whatever `do_install` the class provides).

---

## Path semantics (read this)

Three different bases, easy to mix up:

- **Relative to `S` (the build output dir):** `install.bindir/sbindir/libdir`
  and `install.custom[].src`. `S` is `${WORKDIR}/src` (local-source),
  `${WORKDIR}/git` (git), or `${WORKDIR}` (prebuilt). These name **build
  products** or files inside the fetched source/tarball.
- **Relative to the app dir** (`src/apps/<name>/`): `config[].src`,
  `files[].src`, `service.unit`, and `binary.url`'s `file://` path. These are
  files **you ship in the app dir**; the generator stages them into `WORKDIR`.
- **Absolute target paths:** every `dst` (in `config`, `files`,
  `install.custom`) — where the file lands in the image rootfs.

---

## What gets generated

The bundled `hello-world` app (`local-source` + `make`, `install.bindir:
[hello-world]`, `license: MIT`) generates this recipe — a faithful map from the
manifest:

```bash
# AUTO-GENERATED by bin/gen-apps.py - DO NOT EDIT.
# Edit src/apps/<name>/app.yaml and run `make apps`.

SUMMARY = "Demo C program showing the local-source + make app integration"

LICENSE = "MIT"

LIC_FILES_CHKSUM = "file://${WORKDIR}/LICENSE;md5=…"

SRC_URI = "file://src \
           file://LICENSE"

S = "${WORKDIR}/src"

do_compile() {
    oe_runmake CC="${CC}" CXX="${CXX}" LD="${LD}" AR="${AR}" \
        CFLAGS="${CFLAGS}" CXXFLAGS="${CXXFLAGS}" LDFLAGS="${LDFLAGS}"
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/hello-world ${D}${bindir}/
}
```

Adding (say) a `service`, a `config` entry and a `users` entry would append
`inherit systemd useradd`, `SYSTEMD_*`/`USERADD_*` assignments, and
`do_install:append()` blocks that stage the unit and config from `${WORKDIR}`.

Every generated recipe is collected into `packagegroup-custom-apps` and installed
by the generated image recipe (`adi-sc5xx-custom`), so a plain `make image`
ships all configured apps.

---

## Validation rules & gotchas

`make apps` fails fast (before any build) on:

- `name` missing, malformed, or `≠` the directory name.
- `version` missing or not matching `^[A-Za-z0-9.+~_-]+$`.
- missing `summary` or `license`.
- `kind` not one of the four.
- `kind: local-source` without a `src/` directory.
- `kind: git` without `git.url` **and** `git.rev`.
- `kind: prebuilt-*` without `binary.url`; a remote URL without `binary.sha256`;
  or a `file://` URL pointing at a missing file.
- a `license` other than `CLOSED` with no `LICENSE`/`COPYING` file present.
- a `config[].src`, `files[].src`, or `service.unit` that doesn't exist.
- an `install.custom[]` entry missing `src` or `dst`.

Gotchas:

- **Quote modes.** Write `mode: "0644"`, not `mode: 0644` — unquoted YAML may
  parse it as a number and you'll get the wrong permission bits.
- **`name` == directory name**, always. Renaming the app means renaming the dir.
- **`git.rev` is a SHA**, not a tag/branch — it pins `SRCREV` reproducibly.
- **`CLOSED`** skips the license-file requirement and `LIC_FILES_CHKSUM` — use it
  for internal/proprietary apps with no shippable license text.
- **`config` vs `files`:** use `config` for user-editable files that must survive
  package upgrades (they become `CONFFILES`); use `files` for everything else.
- The generated `src/layers/meta-custom-apps/` is **disposable** — edit
  `app.yaml`, never the recipe; re-run `make apps`.

# Worked example — SC598 SOM Rev E to a Linux login over NFS

My personal runbook: the exact steps and settings that took a fresh
**ADSP-SC598-SOM Rev E** (Carrier Rev D) with empty flash all the way to a Linux
login — U-Boot loaded over **JTAG**, kernel `fitImage` pulled over **TFTP**, and
the root filesystem mounted over **NFS** from this build host.

> Settings: [`config.mk.local`](config.mk.local). Overview: the
> [Example settings](README.md#example-settings) section of the main README.

## My settings

These live in [`config.mk.local`](config.mk.local). Either copy the assignments
into your `config.mk`, or load the file by adding `-include
$(PROJECT_ROOT)/config.mk.local` immediately **before** `include config.mk` in
the `Makefile`.

| Variable | Value | Used by |
|---|---|---|
| `SOM_REV` / `CRR_REV` | `E` / `D` | `make image` — selects the Rev-E device tree (the console fix) |
| `TFTP_DIR` | `/mnt/nvme2n1/data02/tftp` | `make tftp` / `make tftp-status` |
| `SDK_INSTALL_DIR` | `/mnt/nvme2n1/data02/adi-sdk/$(DISTRO)/$(SDK_VERSION)` | `make openocd` / `make gdb` |
| `NFS_DIR` | `/mnt/nvme2n1/data02/nfs/sc598-rootfs` | `make nfs-setup` / `make nfs-status` |
| `BOARD_IP` / `HOST_IP` | `192.168.2.50` / `192.168.2.180` | the NFS-root `bootargs` |

**Hardware:** board DEBUG → ICE-1000 → host USB; board USB/UART → host; board
Ethernet → same subnet as `HOST_IP`; BMODE in the JTAG/no-boot position (bmode 0).

## 0. Build (once)

```sh
make image          # builds with SOM_REV=E -> Rev-E u-boot + kernel + rootfs
```

## 1. Host-side prep

```sh
make tftp           # stage fitImage into TFTP_DIR (/mnt/nvme2n1/data02/tftp)
make tftp-status    # confirm a TFTP daemon serves that dir
make nfs-setup      # install nfsd, extract rootfs into NFS_DIR, export it  (sudo)
make nfs-status     # confirm the export is live + print the exact NFS bootargs
```

## 2. Three terminals for JTAG bring-up (all open at once)

**Terminal 1 — OpenOCD** (holds the JTAG link; leave it running):
```sh
make openocd        # OPENOCD_SUDO=sudo (default) for ICE USB access; serves GDB on :3333
```

**Terminal 3 — serial console** (open it now so you catch the boot banner):
```sh
make terminal       # minicom on the FT4232H console channel @ 115200; exit Ctrl-A X
```
If several ports are listed, pick the FT4232H **UART** channel (ch.B/C/D, *not*
ch.A which is JTAG): `make list-serial-ports`, then `make terminal
SERIAL_PORT=/dev/serial/by-id/usb-FTDI_...-if0N-port0`.

**Terminal 2 — GDB** (loads U-Boot into DDR over JTAG):
```sh
make gdb            # connects to :3333, auto-loads the SPL symbols
```
then at the `(gdb)` prompt:
```text
load                                              # load SPL into L2 SRAM
c                                                 # SPL inits DDR, then spins "load U-Boot proper via JTAG"
<Ctrl-C>                                          # halt at the spin
load /mnt/nvme2n1/data02/gna-yocto/adsp-sc598-custom/src/build/tmp/deploy/images/adsp-sc598-som-ezkit/u-boot-proper-sc598-som-ezkit.elf
c                                                 # run U-Boot proper
```
Watch Terminal 3: the `U-Boot ...` banner appears, then **press a key** at "Hit
any key to stop autoboot" to land on the `=>` prompt.

## 3. Boot Linux over NFS — in Terminal 3, at the `=>` prompt

```text
setenv bootargs console=ttySC0,115200 earlycon=adi_uart,0x31003000 mem=224M ip=192.168.2.50:192.168.2.180::255.255.255.0:sc598:eth0:off nfsroot=192.168.2.180:/mnt/nvme2n1/data02/nfs/sc598-rootfs,nfsvers=3,tcp
tftp 0x90000000 fitImage
bootm 0x90000000
```

`make nfs-status` prints this exact line for the current `BOARD_IP` / `HOST_IP` /
`NFS_DIR`. Note: **no `root=`** — ADI's initramfs greps `nfsroot=` first, mounts
it, and `switch_root`s in. `0x90000000` is a scratch load address (DDR base); the
9.6 MB `fitImage` lands clear of where `bootm` unpacks kernel/dtb/ramdisk.

## 4. Log in

```text
adsp-sc598-som-ezkit login: root
Password: adi
```

Username `root`, password **`adi`** — the ADI distro's default, set in
`adsp-sc5xx.bbclass` (`PASSWD_ROOT` = a SHA-256 crypt of `adi`), which overrides
the `debug-tweaks` empty password. You are now in the full custom image, running
its rootfs live from `/mnt/nvme2n1/data02/nfs/sc598-rootfs` — edit there on the
host, reboot, changes are live. Run `passwd` to change it; `ssh root@192.168.2.50`
works once you permit root SSH.

## Notes / gotchas

- The console only works because `SOM_REV=E` builds the ADP5588-based device
  tree; the BSP default `D` leaves the SC598-SOM Rev E console dead (it drives a
  MCP23018 @ i2c2 `0x20` that does not exist on Rev E).
- `ip=` brings up `eth0` before the NFS mount (`CONFIG_IP_PNP`). Drop `nfsroot=`
  (and `root=`) entirely and the same initramfs instead drops to a RAM-only
  busybox shell from the fitImage's bundled ramdisk — handy for a first boot.
- To retry after a kernel panic, reset and re-run Terminal 2's sequence
  (`load` SPL → `c` → `Ctrl-C` → `load` proper → `c`); the SPL re-inits DDR each
  time, so re-`tftp` the fitImage before `bootm`.

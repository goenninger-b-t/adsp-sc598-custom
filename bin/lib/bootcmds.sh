# bin/lib/bootcmds.sh
#
# Shared emitter for the U-Boot network-boot command sequence that brings the
# ADSP-SC598 up to a Linux prompt. Sourced by BOTH:
#
#   bin/nfs-server.sh   - to print the ready-to-paste bootargs in `make nfs-status`
#   bin/boot-run.sh     - to feed `make boot` the exact lines it types at the
#                         U-Boot `=>` prompt over the serial console
#
# Keeping the construction in one place is the whole point: `make boot` and
# `make nfs-status` can never drift, because they build the bootargs from the
# same code.
#
# Inputs are environment variables (the Makefile passes them through from
# config.mk). Every one has a default, so the functions are safe to call
# stand-alone:
#
#   BOARD_IP            board static IP      -> U-Boot ipaddr + ip= client field
#   HOST_IP             this host's IP       -> serverip (TFTP) + NFS server
#   BOARD_NETMASK       netmask              -> ip= netmask field   (255.255.255.0)
#   BOARD_GATEWAY       gateway (optional)   -> ip= gateway field   (empty)
#   BOARD_HOSTNAME      hostname             -> ip= hostname field   (sc598)
#   BOOT_NETDEV         kernel net device    -> ip= device field     (eth0)
#   NFS_DIR             exported rootfs dir  -> nfsroot path
#   NFS_VERS            NFS protocol version -> nfsroot nfsvers       (3)
#   BOOT_CONSOLE        console=...          -> bootargs console      (ttySC0,115200)
#   BOOT_EARLYCON       earlycon=...         -> bootargs earlycon     (adi_uart,0x31003000)
#   BOOT_MEM            mem=...              -> bootargs mem           (224M)
#   BOOT_FITIMAGE_ADDR  DDR load scratch     -> tftp/bootm address     (0x90000000)
#   BOOT_FITIMAGE_NAME  FIT filename         -> tftp filename          (fitImage)
#   BOOT_METHOD         nfs | ramdisk        -> selects the bootargs shape (nfs)

# Defaults (do not override a value the caller already exported).
: "${BOARD_IP:=}"
: "${HOST_IP:=}"
: "${BOARD_NETMASK:=255.255.255.0}"
: "${BOARD_GATEWAY:=}"
: "${BOARD_HOSTNAME:=sc598}"
: "${BOOT_NETDEV:=eth0}"
: "${NFS_DIR:=}"
: "${NFS_VERS:=3}"
: "${BOOT_CONSOLE:=ttySC0,115200}"
: "${BOOT_EARLYCON:=adi_uart,0x31003000}"
: "${BOOT_MEM:=224M}"
: "${BOOT_FITIMAGE_ADDR:=0x90000000}"
: "${BOOT_FITIMAGE_NAME:=fitImage}"
: "${BOOT_METHOD:=nfs}"

# The kernel ip= bootarg:  ip=<client>:<server>:<gw>:<netmask>:<host>:<dev>:<autoconf>
# An empty BOARD_GATEWAY deliberately yields the "::" the SC598 boots with today.
bootcmds_ip_field() {
    printf 'ip=%s:%s:%s:%s:%s:%s:off' \
        "${BOARD_IP:-<board-ip>}" "${HOST_IP:-<host-ip>}" "${BOARD_GATEWAY}" \
        "${BOARD_NETMASK}" "${BOARD_HOSTNAME}" "${BOOT_NETDEV}"
}

# The bootargs VALUE (without the leading 'setenv bootargs '). Shape per method:
#   nfs     - console/earlycon/mem + ip= + nfsroot=  (NO root= so ADI's initramfs
#             takes the nfsroot branch and switch_root's into the network rootfs)
#   ramdisk - console/earlycon/mem only             (the fitImage's embedded
#             initramfs gives a busybox shell; no network rootfs)
bootcmds_bootargs() {
    local base="console=${BOOT_CONSOLE} earlycon=${BOOT_EARLYCON} mem=${BOOT_MEM}"
    case "${BOOT_METHOD}" in
        nfs)
            printf '%s %s nfsroot=%s:%s,nfsvers=%s,tcp' \
                "$base" "$(bootcmds_ip_field)" \
                "${HOST_IP:-<host-ip>}" "${NFS_DIR:-<nfs-dir>}" "${NFS_VERS}"
            ;;
        ramdisk)
            printf '%s' "$base"
            ;;
        *)
            echo "bootcmds: unknown BOOT_METHOD='${BOOT_METHOD}' (use nfs|ramdisk)" >&2
            return 1
            ;;
    esac
}

# 'setenv bootargs <value>' as one U-Boot line.
bootcmds_setenv_bootargs() { printf 'setenv bootargs %s\n' "$(bootcmds_bootargs)"; }

# Network bring-up + the ping gate. `make boot` treats a failed ping as fatal
# (no point tftp'ing into a dead link), so this is emitted before the load.
bootcmds_network_setup() {
    printf 'setenv ipaddr %s\n'   "${BOARD_IP:-<board-ip>}"
    printf 'setenv serverip %s\n' "${HOST_IP:-<host-ip>}"
    printf 'setenv netmask %s\n'  "${BOARD_NETMASK}"
    [ -n "${BOARD_GATEWAY}" ] && printf 'setenv gatewayip %s\n' "${BOARD_GATEWAY}"
    printf 'ping ${serverip}\n'
}

# tftp the FIT bundle into DDR and boot it.
bootcmds_load() {
    printf 'tftp %s %s\n' "${BOOT_FITIMAGE_ADDR}" "${BOOT_FITIMAGE_NAME}"
    printf 'bootm %s\n'   "${BOOT_FITIMAGE_ADDR}"
}

# The full ordered sequence `make boot` types at the `=>` prompt.
bootcmds_full() {
    bootcmds_network_setup
    bootcmds_setenv_bootargs
    bootcmds_load
}

# Indented, human-facing variant for `make nfs-status` (bootargs + tftp + bootm).
bootcmds_print_uboot() {
    bootcmds_setenv_bootargs | sed 's/^/    /'
    bootcmds_load            | sed 's/^/    /'
}

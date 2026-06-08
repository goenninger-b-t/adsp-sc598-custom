# Override meta-adi's initramfs init script (recipes-adi/initramfs-init) with our
# copy that RETRIES the NFS-root mount. The stock script mounts NFS once; if the
# network link/ARP isn't ready yet it fails ("No route to host"), /rootmount stays
# unmounted, switch_root fails, and the kernel panics. This bites under PREEMPT_RT
# (LINUX_RT=1), where threaded IRQs shift the boot timing so the mount fires too
# early. The recipe's SRC_URI is "file://init-ramfs.sh"; FILESEXTRAPATHS:prepend
# makes bitbake find OUR files/init-ramfs.sh first, transparently replacing it.
#
# This applies to every boot (nfs + ramdisk); it only changes behaviour on the
# nfsroot= path, and only when the first mount attempt fails.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

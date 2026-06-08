#!/bin/sh
#
# meta-custom-bsp override of meta-adi's recipes-adi/initramfs-init/init-ramfs.sh.
# IDENTICAL to the stock ADI script except that the NFS-root mount is wrapped in a
# RETRY loop (see the nfsroot= branch). Rationale: the stock script mounts NFS
# exactly once, immediately after the kernel ip= autoconfig. The link/ARP is often
# not ready yet - especially under PREEMPT_RT (LINUX_RT=1), where threaded IRQs
# shift the boot timing - so the single mount fails ("No route to host"),
# /rootmount stays unmounted, switch_root fails, and the kernel panics
# ("Attempted to kill init"). Retrying for ~30s rides out the settle time.
# Keep this in sync with the stock script when bumping the ADI BSP.

PATH=/sbin:/bin:/usr/sbin:/usr/bin
rootdev=""
opt="rw"
wait=""
fstype="auto"

do_splash(){
printf " \

         Analog Initial Ram Filesystem
                www.analog.com
              www.yoctoproject.org

Analog [Initramfs]: Preparing Operating System....
Analog [Initramfs]: Mounting Root File System...
" > /dev/kmsg
}

do_mount_fs() {
	grep -q "$1" /proc/filesystems || return
	test -d "$2" || mkdir -p "$2"
	mount -t "$1" "$1" "$2"
}

mkdir -p /proc
mkdir -p /rootmount
mount -t proc proc /proc

do_mount_fs sysfs /sys
do_mount_fs debugfs /sys/kernel/debug
do_mount_fs devtmpfs /dev
do_mount_fs devpts /dev/pts
do_mount_fs tmpfs /dev/shm

do_splash

if [ "$(grep nfsroot= /proc/cmdline)" ]; then
	NFS_ROOT=$(cat /proc/cmdline | sed -e 's/^.*nfsroot=//' -e 's/ .*$//')
	NFS_SERVER=$(printf ${NFS_ROOT} | sed -e 's/,.*//')
	NFS_OPTS=$(printf ${NFS_ROOT} | sed -e 's/,/REP/' -e 's/.*REP//')
	echo "Analog [Initramfs]: Switching RFS to NFS mount (${NFS_OPTS},${NFS_SERVER})..." > /dev/kmsg
	# meta-custom-bsp: retry the NFS mount instead of trying once. The link/ARP
	# may not be ready the instant ip= autoconfig finishes (notably under
	# PREEMPT_RT), and a single early failure would leave /rootmount unmounted ->
	# switch_root fails -> kernel panic. Retry for up to ~30s.
	nfs_try=0
	while ! mount -t nfs -o nolock,$NFS_OPTS $NFS_SERVER /rootmount; do
		nfs_try=$((nfs_try + 1))
		if [ "$nfs_try" -ge 30 ]; then
			echo "Analog [Initramfs]: NFS mount still failing after ${nfs_try}s - giving up" > /dev/kmsg
			break
		fi
		echo "Analog [Initramfs]: NFS not ready, retry ${nfs_try} ..." > /dev/kmsg
		sleep 1
	done
	exec switch_root /rootmount /sbin/init > /dev/kmsg
elif [ "$(grep root= /proc/cmdline)" ]; then
	for bootarg in $(cat /proc/cmdline); do
		case "$bootarg" in
			root=*) rootdev="${bootarg##root=}" ;;
			ro) opt="ro" ;;
			rootwait) wait="yes" ;;
			rootfstype=*) fstype="${bootarg##rootfstype=}" ;;
		esac
	done

	if [ -n "${wait}" -a ! -b "${rootdev}" ]; then
		echo "Waiting for ${rootdev}..."  > /dev/kmsg
		while true; do
			test -b "${rootdev}" && break
			sleep 1
		done
	fi

	echo "Analog [Initramfs]: Switching RFS to ${fstype},${rootdev}..." > /dev/kmsg
	mount -t "${fstype}" -o "${opt}" "${rootdev}" /rootmount
	exec switch_root /rootmount /sbin/init > /dev/kmsg
else
	echo "Analog [Initramfs]: No root device found, dropping to getty" > /dev/kmsg

	cat /etc/hostname > /proc/sys/kernel/hostname

	/sbin/udhcpc eth0 &

	while [ 1 ]; do
		/sbin/getty 115200 /dev/ttySC0 linux
	done
fi

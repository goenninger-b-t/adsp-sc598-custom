# Build-time Linux <-> SHARC+ DDR split for the ADSP-SC598 SOM-EZKIT.
#
# The SC598 shares one DDR between the Cortex-A55 (Linux) and the SHARC+ cores.
# config.mk's LINUX_MEM (the RAM assigned to Linux; the SHARC+ cores get the rest
# of physical DDR) is resolved by bin/configure-build.sh into the Linux DDR window
#   LINUX_MEM_BASE / LINUX_MEM_SIZE   (Linux occupies the TOP of DDR)
# and written into conf/local.conf.
#
# NOTE: U-Boot's bootm rewrites the kernel /memory node from CFG_SYS_SDRAM_*
# (arch_fixup_fdt), so the OPERATIVE lever is the u-boot-adi bbappend. We ALSO
# rewrite the kernel DT /memory node (and the mem= bootarg) here, from the same
# LINUX_MEM_* vars, so the DTB stays consistent with what U-Boot reports.
#
# Only the DDR memory node is touched (its base is in 0x8xxxxxxx/0x9xxxxxxx); the
# L2-SRAM memory@20040000 node, the reserved-memory/SHARC nodes, and the SPI-NOR
# partition regs all start 0x0/0x2 and are deliberately left alone.

LINUX_MEM ?= ""
LINUX_MEM_BASE ?= ""
LINUX_MEM_SIZE ?= ""
LINUX_MEM_BASE_NODE ?= ""

# NOTE: every ${...} below is a real bitbake variable (bitbake expands them before
# the shell runs). Do NOT use shell parameter expansion like ${VAR#0x} here -
# bitbake mangles it; that is why the node unit-address is passed pre-stripped as
# LINUX_MEM_BASE_NODE from bin/configure-build.sh.
do_configure:append:adsp-sc598-som-ezkit () {
	if [ -n "${LINUX_MEM_BASE}" ] && [ -n "${LINUX_MEM_SIZE}" ] && [ -n "${LINUX_MEM_BASE_NODE}" ]; then
		dts="${S}/arch/arm64/boot/dts/adi/sc598-som.dtsi"
		if [ -f "$dts" ]; then
			sed -i \
				-e "s|memory@[89][0-9a-fA-F]* {|memory@${LINUX_MEM_BASE_NODE} {|" \
				-e "s|reg = <0x[89][0-9a-fA-F]* 0x[0-9a-fA-F]*>;|reg = <${LINUX_MEM_BASE} ${LINUX_MEM_SIZE}>;|" \
				-e "s|mem=[0-9]*[KkMmGg]|mem=${LINUX_MEM}|" \
				"$dts"
			bbnote "linux-mem: Linux DDR window = ${LINUX_MEM_BASE} + ${LINUX_MEM_SIZE} (mem=${LINUX_MEM}); SHARC+ gets the rest"
		else
			bbwarn "linux-mem: $dts not found; DT /memory node left at its default"
		fi
	fi
}

# Re-run do_configure (and thus rebuild the DTB) whenever the split changes.
do_configure[vardeps] += "LINUX_MEM LINUX_MEM_BASE LINUX_MEM_SIZE LINUX_MEM_BASE_NODE"

# Build-time Linux <-> SHARC+ DDR split for the ADSP-SC598 SOM-EZKIT (U-Boot side).
#
# U-Boot's bootm REWRITES the kernel device-tree /memory node from its own
# CFG_SYS_SDRAM_BASE/SIZE (generic arch_fixup_fdt -> fdt_fixup_memory_banks,
# arch/arm/lib/bootm.c) - so those, not the kernel DTB alone, are what Linux
# ultimately gets. We therefore set CFG_SYS_SDRAM_BASE/SIZE to the Linux DDR
# window (LINUX_MEM_BASE / LINUX_MEM_SIZE, derived from config.mk's LINUX_MEM by
# bin/configure-build.sh). The kernel linux-adi bbappend sets the matching DT
# /memory node so the two always agree.
#
# As in the kernel bbappend, every ${...} below is a real bitbake variable; do
# NOT use shell parameter expansion (${VAR#0x} etc.) - bitbake mangles it.

LINUX_MEM_BASE ?= ""
LINUX_MEM_SIZE ?= ""

do_configure:append:adsp-sc598-som-ezkit () {
	if [ -n "${LINUX_MEM_BASE}" ] && [ -n "${LINUX_MEM_SIZE}" ]; then
		h="${S}/include/configs/sc598-som.h"
		if [ -f "$h" ]; then
			sed -i -E \
				-e "s|(#define[[:space:]]+CFG_SYS_SDRAM_BASE[[:space:]]+)0x[0-9a-fA-F]+|\1${LINUX_MEM_BASE}|" \
				-e "s|(#define[[:space:]]+CFG_SYS_SDRAM_SIZE[[:space:]]+)0x[0-9a-fA-F]+|\1${LINUX_MEM_SIZE}|" \
				"$h"
			bbnote "linux-mem: U-Boot SDRAM base=${LINUX_MEM_BASE} size=${LINUX_MEM_SIZE}"
		else
			bbwarn "linux-mem: $h not found; U-Boot CFG_SYS_SDRAM_* left at default"
		fi
	fi
}

# Rebuild U-Boot whenever the split changes.
do_configure[vardeps] += "LINUX_MEM_BASE LINUX_MEM_SIZE"

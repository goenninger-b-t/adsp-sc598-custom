SUMMARY = "Board DNS resolver configuration (systemd-resolved drop-in)"
DESCRIPTION = "Drops /etc/systemd/resolved.conf.d/10-board-dns.conf to set the \
systemd-resolved DNS server(s) from config.mk's BOARD_DNS, so the board boots with \
a known resolver instead of systemd's compiled-in FallbackDNS (Cloudflare 1.1.1.1, \
which is what the board shows by default - it is NOT set in any BSP layer)."
LICENSE = "CLOSED"

inherit allarch

# The real value is injected into conf/local.conf by bin/configure-build.sh
# (from config.mk's BOARD_DNS). Empty here -> no drop-in is installed.
BOARD_DNS ?= ""

# Config-only recipe: nothing to fetch, configure or compile.
INHIBIT_DEFAULT_DEPS = "1"
do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
	if [ -n "${BOARD_DNS}" ]; then
		install -d ${D}${sysconfdir}/systemd/resolved.conf.d
		cat > ${D}${sysconfdir}/systemd/resolved.conf.d/10-board-dns.conf <<EOF
# Generated from BOARD_DNS (config.mk) by meta-custom-bsp/board-dns - DO NOT EDIT.
# Sets the systemd-resolved DNS server(s), superseding systemd's compiled-in
# FallbackDNS list (Cloudflare 1.1.1.1 first), which the board used by default.
[Resolve]
DNS=${BOARD_DNS}
EOF
	fi
}

# Allow an empty package when BOARD_DNS is unset (board keeps systemd's default).
ALLOW_EMPTY:${PN} = "1"
FILES:${PN} = "${sysconfdir}/systemd/resolved.conf.d"

# Rebuild the drop-in whenever BOARD_DNS changes.
do_install[vardeps] += "BOARD_DNS"

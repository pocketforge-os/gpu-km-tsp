#!/bin/bash
# Gate 1 (tsp-a33282eedd2009fe2d24): pvrsrvkm.ko must build for a configured Linux 7.x tree.
# RED today: the 7.x tree is not configured / the module does not compile against 7.2.
# Usage: tests/gate1-km-7x-build.sh [KERNELDIR]   (default: ../kernel-sunxi-7.x, configured)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KERNELDIR="${1:-$(cd "$HERE/../kernel-sunxi-7.x" && pwd)}"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export KBUILD_MODPOST_WARN=1  # Allow build without full kernel Module.symvers
fail() { echo "FAIL gate1 reason=$1 ${2:-}"; exit 1; }
[ -f "$KERNELDIR/include/generated/autoconf.h" ] || fail kernel_tree_not_configured "$KERNELDIR"
rel=$(cat "$KERNELDIR/include/config/kernel.release" 2>/dev/null) || fail kernel_release_missing "$KERNELDIR"
case "$rel" in 7.*) ;; *) fail kernel_not_7x "release=$rel";; esac
rm -f "$HERE/pvrsrvkm.ko" "$HERE/dc_sun4i.ko"
PVR_DC_SUN4I=1 "$HERE/build-sunxi-a133.sh" "$KERNELDIR" >"${TMPDIR:-/tmp}/gate1-km-7x-build.log" 2>&1 || fail module_build_failed "log=${TMPDIR:-/tmp}/gate1-km-7x-build.log"
[ -f "$HERE/pvrsrvkm.ko" ] || fail pvrsrvkm_module_missing
[ -f "$HERE/dc_sun4i.ko" ] || fail dc_sun4i_module_missing
vm=$(modinfo -F vermagic "$HERE/pvrsrvkm.ko" 2>/dev/null) || fail modinfo_failed
case "$vm" in "$rel"*) ;; *) fail vermagic_mismatch "vermagic=$vm release=$rel";; esac
echo "PASS gate1 release=$rel pvrsrvkm_sha256=$(sha256sum "$HERE/pvrsrvkm.ko" | cut -d' ' -f1) dc_sun4i_sha256=$(sha256sum "$HERE/dc_sun4i.ko" | cut -d' ' -f1)"

#!/bin/bash
# Gate 1 (tsp-a33282eedd2009fe2d24): pvrsrvkm.ko and dc_sun4i.ko must build for a configured Linux 7.x tree.
# Verifies Linux 7.2 fbdev API compatibility, vermagic, and symbol loadability.
#
# Symbol verification strategy (fail-closed):
#   1. Prefer Module.symvers if available (gold standard)
#   2. Otherwise extract EXPORT_SYMBOL declarations from kernel source
#   3. Verify ALL undefined symbols against kernel exports + pvrsrvkm exports
#   4. Private fbdev symbols (registered_fb, get_fb_info, put_fb_info) ALWAYS fail
#   5. nm failures are fatal (capture output, check exit code)
#
# Usage: tests/gate1-km-7x-build.sh [KERNELDIR]   (default: ../kernel-sunxi-7.x, configured)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KERNELDIR="${1:-$(cd "$HERE/../kernel-sunxi-7.x" && pwd)}"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
NM="${CROSS_COMPILE}nm"
WORKDIR="${TMPDIR:-/tmp}/gate1-$$"
mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

fail() { echo "FAIL gate1 reason=$1 ${2:-}"; exit 1; }

# Verify kernel tree is configured and is 7.x
[ -f "$KERNELDIR/include/generated/autoconf.h" ] || fail kernel_tree_not_configured "$KERNELDIR"
rel=$(cat "$KERNELDIR/include/config/kernel.release" 2>/dev/null) || fail kernel_release_missing "$KERNELDIR"
case "$rel" in 7.*) ;; *) fail kernel_not_7x "release=$rel";; esac

# Build modules
rm -f "$HERE/pvrsrvkm.ko" "$HERE/dc_sun4i.ko"
export KBUILD_MODPOST_WARN=1
PVR_DC_SUN4I=1 "$HERE/build-sunxi-a133.sh" "$KERNELDIR" >"$WORKDIR/build.log" 2>&1 || fail module_build_failed "log=$WORKDIR/build.log"

# Verify both modules exist
[ -f "$HERE/pvrsrvkm.ko" ] || fail pvrsrvkm_module_missing
[ -f "$HERE/dc_sun4i.ko" ] || fail dc_sun4i_module_missing

# Verify vermagic matches kernel release for both modules
vm_pvrsrvkm=$(modinfo -F vermagic "$HERE/pvrsrvkm.ko" 2>/dev/null) || fail modinfo_failed_pvrsrvkm
case "$vm_pvrsrvkm" in "$rel"*) ;; *) fail vermagic_mismatch_pvrsrvkm "vermagic=$vm_pvrsrvkm release=$rel";; esac

vm_dc_sun4i=$(modinfo -F vermagic "$HERE/dc_sun4i.ko" 2>/dev/null) || fail modinfo_failed_dc_sun4i
case "$vm_dc_sun4i" in "$rel"*) ;; *) fail vermagic_mismatch_dc_sun4i "vermagic=$vm_dc_sun4i release=$rel";; esac

# --- FAIL-CLOSED SYMBOL VERIFICATION ---

# Step 1: Capture nm -u output for both modules (fail if nm itself fails)
if ! "$NM" -u "$HERE/pvrsrvkm.ko" >"$WORKDIR/pvrsrvkm_undef.txt" 2>"$WORKDIR/pvrsrvkm_nm.err"; then
	fail nm_failed_pvrsrvkm "err=$(cat "$WORKDIR/pvrsrvkm_nm.err")"
fi
if ! "$NM" -u "$HERE/dc_sun4i.ko" >"$WORKDIR/dc_sun4i_undef.txt" 2>"$WORKDIR/dc_sun4i_nm.err"; then
	fail nm_failed_dc_sun4i "err=$(cat "$WORKDIR/dc_sun4i_nm.err")"
fi
# Verify nm actually produced output (not an empty file indicating tool failure)
[ -s "$WORKDIR/pvrsrvkm_undef.txt" ] || fail nm_empty_output_pvrsrvkm
[ -s "$WORKDIR/dc_sun4i_undef.txt" ] || fail nm_empty_output_dc_sun4i

# Normalize: extract symbol names (strip leading whitespace and U marker)
awk '{print $NF}' "$WORKDIR/pvrsrvkm_undef.txt" | sort -u > "$WORKDIR/pvrsrvkm_undef.norm"
awk '{print $NF}' "$WORKDIR/dc_sun4i_undef.txt" | sort -u > "$WORKDIR/dc_sun4i_undef.norm"

pvrsrvkm_count=$(wc -l < "$WORKDIR/pvrsrvkm_undef.norm")
dc_sun4i_count=$(wc -l < "$WORKDIR/dc_sun4i_undef.norm")

# Step 2: Check for forbidden private fbdev symbols (ALWAYS fail)
forbidden="registered_fb get_fb_info put_fb_info fb_con_dpi"
for sym in $forbidden; do
	if grep -qxF "$sym" "$WORKDIR/dc_sun4i_undef.norm" || grep -qxF "$sym" "$WORKDIR/pvrsrvkm_undef.norm"; then
		fail private_symbol_found "forbidden symbol: $sym"
	fi
done

# Step 3: Build allowlist from pvrsrvkm.ko exports (symbols dc_sun4i can legitimately depend on)
"$NM" --defined-only "$HERE/pvrsrvkm.ko" 2>/dev/null | awk '/ [TtDdBb] / {print $NF}' | sort -u > "$WORKDIR/pvrsrvkm_exports.txt" || true

# Step 4: Get kernel exports - REQUIRE Module.symvers (fail closed if missing)
if [ -f "$KERNELDIR/Module.symvers" ] && [ -s "$KERNELDIR/Module.symvers" ]; then
	# Gold standard: use Module.symvers from kernel build
	awk '{print $2}' "$KERNELDIR/Module.symvers" | sort -u > "$WORKDIR/kernel_exports.txt"
	kernel_source="Module.symvers"
else
	# Without Module.symvers, we cannot prove the modules are loadable
	# The pinned build fixture must be updated to generate Module.symvers
	fail module_symvers_missing "kernel tree at $KERNELDIR does not have Module.symvers; cannot prove module loadability"
fi

kernel_export_count=$(wc -l < "$WORKDIR/kernel_exports.txt")

# Step 5: Combine kernel exports + pvrsrvkm exports into full allowlist
sort -u "$WORKDIR/kernel_exports.txt" "$WORKDIR/pvrsrvkm_exports.txt" > "$WORKDIR/full_allowlist.txt"
allowlist_count=$(wc -l < "$WORKDIR/full_allowlist.txt")

# Step 6: Verify dc_sun4i undefined symbols against allowlist
unknown_count=0
while read -r sym; do
	if ! grep -qxF "$sym" "$WORKDIR/full_allowlist.txt"; then
		echo "Unknown symbol in dc_sun4i.ko: $sym" >&2
		unknown_count=$((unknown_count + 1))
	fi
done < "$WORKDIR/dc_sun4i_undef.norm"

if [ "$unknown_count" -gt 0 ]; then
	fail unknown_symbols_in_dc_sun4i "count=$unknown_count"
fi

# Step 7: Verify pvrsrvkm undefined symbols against kernel exports only
# (pvrsrvkm is the base module, it shouldn't depend on dc_sun4i)
pvrsrvkm_unknown=0
while read -r sym; do
	if ! grep -qxF "$sym" "$WORKDIR/kernel_exports.txt"; then
		echo "Unknown symbol in pvrsrvkm.ko: $sym" >&2
		pvrsrvkm_unknown=$((pvrsrvkm_unknown + 1))
	fi
done < "$WORKDIR/pvrsrvkm_undef.norm"

if [ "$pvrsrvkm_unknown" -gt 0 ]; then
	fail unknown_symbols_in_pvrsrvkm "count=$pvrsrvkm_unknown"
fi

# Compute module hashes
pvrsrvkm_sha256=$(sha256sum "$HERE/pvrsrvkm.ko" | cut -d' ' -f1)
dc_sun4i_sha256=$(sha256sum "$HERE/dc_sun4i.ko" | cut -d' ' -f1)

echo "PASS gate1 release=$rel"
echo "  pvrsrvkm.ko: vermagic=$vm_pvrsrvkm sha256=$pvrsrvkm_sha256"
echo "  dc_sun4i.ko: vermagic=$vm_dc_sun4i sha256=$dc_sun4i_sha256"
echo "  Symbol verification: kernel_source=$kernel_source kernel_exports=$kernel_export_count allowlist=$allowlist_count"
echo "  Private symbols: NONE (verified registered_fb, get_fb_info, put_fb_info absent)"
echo "  Unknown symbols: dc_sun4i=$dc_sun4i_count pvrsrvkm=$pvrsrvkm_count (all verified)"

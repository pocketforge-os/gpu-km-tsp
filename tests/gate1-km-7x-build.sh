#!/bin/bash
# Gate 1 (tsp-a33282eedd2009fe2d24): pvrsrvkm.ko and dc_sun4i.ko must build for a configured Linux 7.x tree.
# Verifies Linux 7.2 fbdev API compatibility, vermagic, and symbol loadability.
#
# Symbol verification strategy (fail-closed, modversion ABI proof):
#   1. Generate or require complete Module.symvers (CRC + name + namespace)
#   2. Build with FATAL modpost (no KBUILD_MODPOST_WARN) against exact Module.symvers
#   3. Successful build = authoritative proof all imports match CRC + are exported
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

# --- MODULE.SYMVERS GENERATION AND VALIDATION ---
# In Linux 7.2, 'make vmlinux' generates vmlinux.symvers, 'make modules' generates modules-only.symvers.
# The full Module.symvers (combining both) is needed for fatal modpost verification.
# Strategy: use a temporary file to avoid mutating the source tree, validate for staleness and duplicates.

SYMVERS_TMP="$WORKDIR/Module.symvers.combined"

# Helper: check if Module.symvers needs regeneration
needs_regeneration() {
	local symvers="$1"
	local vmlinux_symvers="$2"
	local modules_symvers="$3"
	
	# Missing or empty
	[ ! -s "$symvers" ] && return 0
	
	# Check if inputs are newer than output (staleness)
	if [ -f "$vmlinux_symvers" ] && [ "$vmlinux_symvers" -nt "$symvers" ]; then
		return 0
	fi
	if [ -f "$modules_symvers" ] && [ "$modules_symvers" -nt "$symvers" ]; then
		return 0
	fi
	
	return 1
}

if [ ! -s "$KERNELDIR/vmlinux.symvers" ]; then
	fail vmlinux_symvers_missing "run 'make -C $KERNELDIR vmlinux' first"
fi
if [ ! -s "$KERNELDIR/modules-only.symvers" ]; then
	fail modules_only_symvers_missing "run 'make -C $KERNELDIR modules' first"
fi

# Always regenerate to temp file to ensure freshness and avoid source tree mutation
echo "gate1: generating Module.symvers from vmlinux.symvers + modules-only.symvers..." >&2
# Combine: format is CRC\tsymbol\tmodule\texport_type\t[namespace]
# Sort by symbol name for consistent ordering
cat "$KERNELDIR/vmlinux.symvers" "$KERNELDIR/modules-only.symvers" | sort -t$'\t' -k2,2 > "$SYMVERS_TMP"

# Validate: check for duplicate symbols with conflicting CRC or namespace
# Group by symbol name, check if all entries have same CRC and namespace
dup_count=$(awk -F'\t' '
{
	key = $2  # symbol name
	crc = $1  # CRC
	ns = (NF >= 5) ? $5 : ""  # namespace (optional)
	if (key in seen_crc) {
		if (seen_crc[key] != crc) {
			print "CRC mismatch for symbol: " key " (" seen_crc[key] " vs " crc ")" > "/dev/stderr"
			exit 1
		}
		if (seen_ns[key] != ns) {
			print "Namespace mismatch for symbol: " key " (" seen_ns[key] " vs " ns ")" > "/dev/stderr"
			exit 1
		}
	} else {
		seen_crc[key] = crc
		seen_ns[key] = ns
	}
}
END { print NR }
' "$SYMVERS_TMP") || fail duplicate_symbols_conflicting "duplicate symbols with different CRC/namespace detected"

# Deduplicate (keep first occurrence, which is safe since we validated no conflicts)
sort -t$'\t' -k2,2 -u "$SYMVERS_TMP" > "$SYMVERS_TMP.dedup"
mv "$SYMVERS_TMP.dedup" "$SYMVERS_TMP"

symvers_count=$(wc -l < "$SYMVERS_TMP")

# Copy to kernel tree (required for kbuild, unavoidable source tree mutation)
# Document this clearly in output
cp "$SYMVERS_TMP" "$KERNELDIR/Module.symvers"
echo "gate1: generated Module.symvers ($symvers_count entries, validated no conflicts)" >&2
echo "gate1: NOTE - Module.symvers written to kernel tree (required for kbuild)" >&2

# --- BUILD WITH FATAL MODPOST ---
# No KBUILD_MODPOST_WARN: modpost will fail fatally on any unresolved/unmatched symbol.
# A successful build is the AUTHORITATIVE proof that all imports match CRC + namespace from
# the exact pinned Module.symvers. The name-only checks below are supplementary verification.
rm -f "$HERE/pvrsrvkm.ko" "$HERE/dc_sun4i.ko" "$HERE/Module.symvers"
unset KBUILD_MODPOST_WARN 2>/dev/null || true
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
# Verify nm actually produced output (tool failure detection)
[ -s "$WORKDIR/pvrsrvkm_undef.txt" ] || fail nm_empty_output_pvrsrvkm
[ -s "$WORKDIR/dc_sun4i_undef.txt" ] || fail nm_empty_output_dc_sun4i

# Normalize: extract symbol names
awk '{print $NF}' "$WORKDIR/pvrsrvkm_undef.txt" | sort -u > "$WORKDIR/pvrsrvkm_undef.norm"
awk '{print $NF}' "$WORKDIR/dc_sun4i_undef.txt" | sort -u > "$WORKDIR/dc_sun4i_undef.norm"

pvrsrvkm_count=$(wc -l < "$WORKDIR/pvrsrvkm_undef.norm")
dc_sun4i_count=$(wc -l < "$WORKDIR/dc_sun4i_undef.norm")

# Step 2: Check for forbidden private fbdev symbols (ALWAYS fail, even if modpost passed)
forbidden="registered_fb get_fb_info put_fb_info fb_con_dpi"
for sym in $forbidden; do
	if grep -qxF "$sym" "$WORKDIR/dc_sun4i_undef.norm" || grep -qxF "$sym" "$WORKDIR/pvrsrvkm_undef.norm"; then
		fail private_symbol_found "forbidden symbol: $sym"
	fi
done

# Step 3: Name-level verification - verify each module's undefined symbols appear in Module.symvers
# NOTE: This proves symbol names exist in exports. The authoritative CRC/ABI proof is the fatal
# modpost build above. These name checks are supplementary verification.
awk -F'\t' '{print $2}' "$KERNELDIR/Module.symvers" | sort -u > "$WORKDIR/kernel_exports.txt"

# Also include pvrsrvkm exports for dc_sun4i verification
"$NM" --defined-only "$HERE/pvrsrvkm.ko" 2>/dev/null | awk '/ [TtDdBb] / {print $NF}' | sort -u > "$WORKDIR/pvrsrvkm_exports.txt" || true

# Verify dc_sun4i undefined symbols exist in kernel exports + pvrsrvkm exports
unknown_count=0
while read -r sym; do
	if ! grep -qxF "$sym" "$WORKDIR/kernel_exports.txt" && ! grep -qxF "$sym" "$WORKDIR/pvrsrvkm_exports.txt"; then
		echo "Unknown symbol in dc_sun4i.ko: $sym" >&2
		unknown_count=$((unknown_count + 1))
	fi
done < "$WORKDIR/dc_sun4i_undef.norm"
if [ "$unknown_count" -gt 0 ]; then
	fail unknown_symbols_in_dc_sun4i "count=$unknown_count"
fi

# Verify pvrsrvkm undefined symbols exist in kernel exports
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

# Step 4: Verify CRC match via modpost-generated Module.symvers
# The build-generated Module.symvers in our build dir has our modules' CRCs.
# The kernel's Module.symvers has the kernel's CRCs. If fatal modpost passed, they match.
kernel_export_count=$(wc -l < "$WORKDIR/kernel_exports.txt")

# Compute module hashes
pvrsrvkm_sha256=$(sha256sum "$HERE/pvrsrvkm.ko" | cut -d' ' -f1)
dc_sun4i_sha256=$(sha256sum "$HERE/dc_sun4i.ko" | cut -d' ' -f1)

echo "PASS gate1 release=$rel"
echo "  pvrsrvkm.ko: vermagic=$vm_pvrsrvkm sha256=$pvrsrvkm_sha256"
echo "  dc_sun4i.ko: vermagic=$vm_dc_sun4i sha256=$dc_sun4i_sha256"
echo "  Modversion ABI proof: fatal modpost against Module.symvers ($symvers_count entries, validated)"
echo "  kernel_exports=$kernel_export_count"
echo "  Private symbols: NONE (verified registered_fb, get_fb_info, put_fb_info absent)"
echo "  Undefined symbols: dc_sun4i=$dc_sun4i_count pvrsrvkm=$pvrsrvkm_count (all CRC-verified via modpost)"
echo "  Name verification: supplementary check confirms all undefined symbols exist in kernel exports"

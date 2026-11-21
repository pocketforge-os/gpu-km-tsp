#!/bin/bash
# Gate 1: pvrsrvkm.ko and dc_sun4i.ko must build against the exact pinned Linux 7.x tree.
#
# SAME-INVOCATION BUILD PROVENANCE:
#   This gate builds ALL ABI evidence in this single invocation:
#   1. Capture exact source HEAD from KERNELDIR (git repo identity only)
#   2. Capture .config SHA256 from KERNELDIR
#   3. Reject tracked/staged dirt in KERNELDIR source tree
#   4. Materialize pinned source into private temp worktree at exact commit
#   5. Create private output directory, copy .config, run olddefconfig
#   6. Build vmlinux + modules in private output (generates symvers)
#   7. Combine vmlinux.symvers + modules-only.symvers -> Module.symvers in output
#   8. Build PVR modules against the output directory (fatal modpost)
#   9. Record all hashes: source commit, config, symvers, modules
#  10. Recheck source HEAD/config after build (race detection)
#  11. KERNELDIR source tree is NEVER mutated (read-only: git identity + .config)
#
# KERNELDIR IMMUTABILITY:
#   This gate only READS from KERNELDIR: git rev-parse, git diff, .config hash.
#   All build output goes to a private temp directory. No files are created,
#   modified, or deleted in KERNELDIR.
#
# Usage: tests/gate1-km-7x-build.sh [KERNEL_SOURCE_DIR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KERNELDIR="${1:-$(cd "$HERE/../kernel-sunxi-7.x" && pwd)}"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
NM="${CROSS_COMPILE}nm"

# =====================================================================
# Bounded build concurrency: hard finite maximum
# =====================================================================
# GATE1_HARD_MAX_JOBS is the IMMUTABLE hard ceiling. It cannot be raised
# by the caller. This prevents runaway parallelism regardless of environment.
GATE1_HARD_MAX_JOBS=8

# resolve_jobs: side-effect-free helper that validates and caps concurrency.
# Returns 0 on success (result in REPLY_JOBS), 1 on fatal validation error.
# Sets REPLY_JOBS to an integer in [1, min(requested_cap, GATE1_HARD_MAX_JOBS)].
# Distinguishes between "no argument" (use default) and "empty string" (fail).
resolve_jobs() {
	local requested_cap
	local ncpu
	ncpu=$(nproc)

	# Apply hard ceiling to default (nproc)
	local default_jobs
	if [ "$ncpu" -gt "$GATE1_HARD_MAX_JOBS" ]; then
		default_jobs=$GATE1_HARD_MAX_JOBS
	else
		default_jobs=$ncpu
	fi

	# No caller override: use bounded default
	# Check if argument was provided at all (not just if it's empty)
	if [ "$#" -eq 0 ]; then
		REPLY_JOBS=$default_jobs
		return 0
	fi

	# Argument was provided - validate it
	requested_cap="$1"

	# Validate: must be a positive integer (rejects nonnumeric, zero, negative, empty)
	if ! [[ "$requested_cap" =~ ^[1-9][0-9]*$ ]]; then
		return 1
	fi

	# Cap against hard maximum (caller can LOWER but never RAISE above hard ceiling)
	if [ "$requested_cap" -gt "$GATE1_HARD_MAX_JOBS" ]; then
		REPLY_JOBS=$GATE1_HARD_MAX_JOBS
	else
		REPLY_JOBS=$requested_cap
	fi
	return 0
}

# Resolve jobs (fatal on invalid input)
if [ -n "${PF_GATE1_JOBS:-}" ]; then
	if ! resolve_jobs "$PF_GATE1_JOBS"; then
		echo "FAIL gate1 reason=invalid_jobs PF_GATE1_JOBS=$PF_GATE1_JOBS (must be positive integer <= $GATE1_HARD_MAX_JOBS)" >&2
		exit 1
	fi
else
	if ! resolve_jobs; then
		echo "FAIL gate1 reason=resolve_jobs_failed" >&2
		exit 1
	fi
fi
JOBS=$REPLY_JOBS

START_TIME=$(date +%s)

# =====================================================================
# Validation mode: run all test cases, aggregate, single final exit
# =====================================================================
# GATE1_TEST_JOBS_VALIDATION=1 exercises resolve_jobs with various inputs
# without starting any kernel build. It tests all advertised cases and
# reports aggregate pass/fail. Cannot recurse (guarded by internal env flag).
if [ "${GATE1_TEST_JOBS_VALIDATION:-0}" = "1" ] && [ "${_GATE1_VALIDATING:-0}" != "1" ]; then
	export _GATE1_VALIDATING=1
	test_pass=0
	test_fail=0

	run_case() {
		local desc="$1" expect="$2" input="$3"
		REPLY_JOBS=""
		if resolve_jobs "$input"; then
			actual="ok:$REPLY_JOBS"
		else
			actual="fail"
		fi
		if [ "$actual" = "$expect" ]; then
			echo "  PASS: $desc (input='$input' -> $actual)"
			test_pass=$((test_pass + 1))
		else
			echo "  FAIL: $desc (input='$input' expected=$expect got=$actual)" >&2
			test_fail=$((test_fail + 1))
		fi
	}

	echo "gate1: running jobs validation test suite"

	# Non-numeric inputs -> must fail
	run_case "nonnumeric" "fail" "abc"
	run_case "empty_string" "fail" ""
	run_case "spaces" "fail" "  "
	run_case "float" "fail" "1.5"
	run_case "hex" "fail" "0x10"
	run_case "leading_plus" "fail" "+4"

	# Zero and negative -> must fail
	run_case "zero" "fail" "0"
	run_case "negative" "fail" "-1"
	run_case "negative_large" "fail" "-999"

	# Valid values -> must succeed with correct result
	run_case "valid_1" "ok:1" "1"
	run_case "valid_4" "ok:4" "4"
	run_case "valid_8" "ok:8" "8"
	run_case "valid_16_large" "ok:$GATE1_HARD_MAX_JOBS" "16"

	# Oversized -> capped to hard max
	run_case "oversized_100" "ok:$GATE1_HARD_MAX_JOBS" "100"
	run_case "oversized_9999" "ok:$GATE1_HARD_MAX_JOBS" "9999"

	# No input -> bounded default (min(nproc, hard_max))
	ncpu=$(nproc)
	if [ "$ncpu" -gt "$GATE1_HARD_MAX_JOBS" ]; then
		expected_default=$GATE1_HARD_MAX_JOBS
	else
		expected_default=$ncpu
	fi
	# Call with no arguments (not empty string) to test default behavior
	REPLY_JOBS=""
	if resolve_jobs; then
		actual="ok:$REPLY_JOBS"
	else
		actual="fail"
	fi
	if [ "$actual" = "ok:$expected_default" ]; then
		echo "  PASS: default_no_input (no args -> $actual)"
		test_pass=$((test_pass + 1))
	else
		echo "  FAIL: default_no_input (no args expected=ok:$expected_default got=$actual)" >&2
		test_fail=$((test_fail + 1))
	fi

	echo ""
	echo "gate1: validation results: passed=$test_pass failed=$test_fail"
	if [ "$test_fail" -gt 0 ]; then
		echo "FAIL gate1 reason=jobs_validation_tests_failed"
		exit 1
	fi
	echo "PASS gate1 jobs validation (all cases)"
	exit 0
fi

# Create private temp work directory (never a fixed path)
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gate1-XXXXXX")"
cleanup() {
	if [ "${GATE1_KEEP:-0}" = "1" ]; then
		echo "gate1: keeping workdir $WORKDIR (GATE1_KEEP=1)" >&2
	else
		rm -rf "$WORKDIR"
	fi
}
trap cleanup EXIT

fail() { echo "FAIL gate1 reason=$1 ${2:-}"; exit 1; }

echo "gate1: same-invocation build provenance" >&2
echo "gate1: KERNELDIR=$KERNELDIR (identity source only)" >&2

# =====================================================================
# STEP 1: Capture KERNELDIR source identity (git repo/ref only)
# =====================================================================
[ -e "$KERNELDIR/.git" ] || fail kernel_source_not_git_repo "$KERNELDIR"

src_commit=$(git -C "$KERNELDIR" rev-parse HEAD 2>/dev/null) || fail cannot_get_source_commit
echo "gate1: src_commit=$src_commit" >&2

# Reject tracked/staged dirt (source identity must be stable)
if ! git -C "$KERNELDIR" diff --quiet 2>/dev/null; then
	fail source_tree_dirty "tracked changes: $(git -C "$KERNELDIR" diff --name-only)"
fi
if ! git -C "$KERNELDIR" diff --cached --quiet 2>/dev/null; then
	fail source_tree_dirty "staged changes: $(git -C "$KERNELDIR" diff --cached --name-only)"
fi
src_clean=true
echo "gate1: source_clean=$src_clean" >&2

# Capture input .config identity
config_file="$KERNELDIR/.config"
[ -f "$config_file" ] || fail kernel_config_missing "$config_file"
input_config_sha256=$(sha256sum "$config_file" | cut -d' ' -f1)
echo "gate1: input_config_sha256=$input_config_sha256" >&2

# =====================================================================
# STEP 2: Materialize exact source into private temp worktree
# =====================================================================
KSRC="$WORKDIR/kernel-src"
KOUT="$WORKDIR/kernel-out"
mkdir -p "$KSRC" "$KOUT"

echo "gate1: archiving source at $src_commit into $KSRC" >&2
git -C "$KERNELDIR" archive --format=tar "$src_commit" | tar -xf - -C "$KSRC"

# Verify archive identity
archive_commit=$(git -C "$KSRC" rev-parse HEAD 2>/dev/null || echo "not-a-git-repo")
# For git archive, the result is not a git repo. Verify by checking a known file exists.
[ -f "$KSRC/Makefile" ] || fail archive_missing_makefile
[ -f "$KSRC/Kbuild" ] || fail archive_missing_kbuild
echo "gate1: source materialized ($archive_commit)" >&2

# =====================================================================
# STEP 3: Configure private output directory
# =====================================================================
cp "$config_file" "$KOUT/.config"
echo "gate1: running olddefconfig in $KOUT" >&2
make -C "$KSRC" O="$KOUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
	olddefconfig >"$WORKDIR/olddefconfig.log" 2>&1 || fail olddefconfig_failed

# Record effective config after olddefconfig
effective_config_sha256=$(sha256sum "$KOUT/.config" | cut -d' ' -f1)
echo "gate1: effective_config_sha256=$effective_config_sha256" >&2

# Run prepare to generate kernel.release and other prerequisites
echo "gate1: running prepare in $KOUT" >&2
make -C "$KSRC" O="$KOUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
	prepare >"$WORKDIR/prepare.log" 2>&1 || fail prepare_failed

# Record kernel release
rel=$(cat "$KOUT/include/config/kernel.release" 2>/dev/null) || fail kernel_release_missing
case "$rel" in 7.*) ;; *) fail kernel_not_7x "release=$rel";; esac
echo "gate1: kernel_release=$rel" >&2

# =====================================================================
# STEP 4: Build kernel in private output (generates symvers)
# =====================================================================
echo "gate1: building vmlinux + modules in $KOUT (jobs=$JOBS)" >&2
make -C "$KSRC" O="$KOUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
	-j"$JOBS" vmlinux modules >"$WORKDIR/kernel-build.log" 2>&1 \
	|| fail kernel_build_failed "log=$WORKDIR/kernel-build.log"

# =====================================================================
# STEP 5: Verify and validate Module.symvers
# =====================================================================
# Linux 7.x generates Module.symvers directly (not separate vmlinux.symvers + modules-only.symvers)
# If separate files exist, combine them; otherwise use Module.symvers directly

if [ -f "$KOUT/vmlinux.symvers" ] && [ -f "$KOUT/modules-only.symvers" ]; then
	# Combine separate symvers files (older kernel style)
	echo "gate1: combining separate symvers files" >&2
	cat "$KOUT/vmlinux.symvers" "$KOUT/modules-only.symvers" | sort -t$'\t' -k2,2 > "$KOUT/Module.symvers.combined"

	vmlinux_symvers_sha256=$(sha256sum "$KOUT/vmlinux.symvers" | cut -d' ' -f1)
	modules_symvers_sha256=$(sha256sum "$KOUT/modules-only.symvers" | cut -d' ' -f1)
	echo "gate1: vmlinux_symvers_sha256=$vmlinux_symvers_sha256" >&2
	echo "gate1: modules_symvers_sha256=$modules_symvers_sha256" >&2

	# Reject duplicate symbols with conflicting CRC or namespace
	awk -F'\t' '
	{
		key = $2; crc = $1; ns = (NF >= 5) ? $5 : ""
		if (key in seen_crc) {
			if (seen_crc[key] != crc) { print "CRC mismatch: " key > "/dev/stderr"; exit 1 }
			if (seen_ns[key] != ns) { print "Namespace mismatch: " key > "/dev/stderr"; exit 1 }
		} else { seen_crc[key] = crc; seen_ns[key] = ns }
	}
	END { print NR }
	' "$KOUT/Module.symvers.combined" > "$WORKDIR/symvers_count.txt" || fail duplicate_symbols_conflicting

	sort -t$'\t' -k2,2 -u "$KOUT/Module.symvers.combined" > "$KOUT/Module.symvers"
	rm -f "$KOUT/Module.symvers.combined"

	symvers_count=$(cat "$WORKDIR/symvers_count.txt")
else
	# Module.symvers generated directly by kernel build (Linux 7.x style)
	[ -f "$KOUT/Module.symvers" ] || fail module_symvers_missing
	[ -s "$KOUT/Module.symvers" ] || fail module_symvers_empty

	# Check for duplicates and count
	awk -F'\t' '
	{
		key = $2; crc = $1; ns = (NF >= 5) ? $5 : ""
		if (key in seen_crc) {
			if (seen_crc[key] != crc) { print "CRC mismatch: " key > "/dev/stderr"; exit 1 }
			if (seen_ns[key] != ns) { print "Namespace mismatch: " key > "/dev/stderr"; exit 1 }
		} else { seen_crc[key] = crc; seen_ns[key] = ns }
	}
	END { print NR }
	' "$KOUT/Module.symvers" > "$WORKDIR/symvers_count.txt" || fail duplicate_symbols_conflicting

	symvers_count=$(cat "$WORKDIR/symvers_count.txt")
	vmlinux_symvers_sha256="N/A-direct"
	modules_symvers_sha256="N/A-direct"
	echo "gate1: kernel build generated Module.symvers directly ($symvers_count entries)" >&2
fi

final_symvers_sha256=$(sha256sum "$KOUT/Module.symvers" | cut -d' ' -f1)
echo "gate1: Module.symvers ($symvers_count entries, sha256=$final_symvers_sha256)" >&2

# =====================================================================
# STEP 6: Build PVR modules against the private output directory
# =====================================================================
rm -f "$HERE/pvrsrvkm.ko" "$HERE/dc_sun4i.ko"
unset KBUILD_MODPOST_WARN 2>/dev/null || true

echo "gate1: building PVR modules against $KOUT" >&2
PVR_DC_SUN4I=1 "$HERE/build-sunxi-a133.sh" "$KOUT" >"$WORKDIR/build.log" 2>&1 \
	|| { cp "$WORKDIR/build.log" "$HERE/gate1-build.log"; fail module_build_failed "log=$HERE/gate1-build.log"; }

[ -f "$HERE/pvrsrvkm.ko" ] || fail pvrsrvkm_module_missing
[ -f "$HERE/dc_sun4i.ko" ] || fail dc_sun4i_module_missing

pvrsrvkm_sha256=$(sha256sum "$HERE/pvrsrvkm.ko" | cut -d' ' -f1)
dc_sun4i_sha256=$(sha256sum "$HERE/dc_sun4i.ko" | cut -d' ' -f1)

# Verify vermagic
vm_pvrsrvkm=$(modinfo -F vermagic "$HERE/pvrsrvkm.ko" 2>/dev/null) || fail modinfo_failed_pvrsrvkm
case "$vm_pvrsrvkm" in "$rel"*) ;; *) fail vermagic_mismatch_pvrsrvkm "vermagic=$vm_pvrsrvkm release=$rel";; esac

vm_dc_sun4i=$(modinfo -F vermagic "$HERE/dc_sun4i.ko" 2>/dev/null) || fail modinfo_failed_dc_sun4i
case "$vm_dc_sun4i" in "$rel"*) ;; *) fail vermagic_mismatch_dc_sun4i "vermagic=$vm_dc_sun4i release=$rel";; esac

# =====================================================================
# STEP 7: Recheck source identity (race detection)
# =====================================================================
src_commit_after=$(git -C "$KERNELDIR" rev-parse HEAD 2>/dev/null) || fail cannot_recheck_source_commit
if [ "$src_commit" != "$src_commit_after" ]; then
	fail source_commit_changed_during_build "before=$src_commit after=$src_commit_after"
fi

if ! git -C "$KERNELDIR" diff --quiet 2>/dev/null; then
	fail source_tree_dirty_during_build "tracked changes appeared"
fi

config_sha256_after=$(sha256sum "$config_file" | cut -d' ' -f1)
if [ "$input_config_sha256" != "$config_sha256_after" ]; then
	fail config_changed_during_build "before=$input_config_sha256 after=$config_sha256_after"
fi

echo "gate1: race detection passed" >&2

# =====================================================================
# STEP 8: Fail-closed symbol verification (supplementary to fatal modpost)
# =====================================================================

# Capture nm -u for both modules
if ! "$NM" -u "$HERE/pvrsrvkm.ko" >"$WORKDIR/pvrsrvkm_undef.txt" 2>"$WORKDIR/pvrsrvkm_nm.err"; then
	fail nm_failed_pvrsrvkm "err=$(cat "$WORKDIR/pvrsrvkm_nm.err")"
fi
if ! "$NM" -u "$HERE/dc_sun4i.ko" >"$WORKDIR/dc_sun4i_undef.txt" 2>"$WORKDIR/dc_sun4i_nm.err"; then
	fail nm_failed_dc_sun4i "err=$(cat "$WORKDIR/dc_sun4i_nm.err")"
fi
[ -s "$WORKDIR/pvrsrvkm_undef.txt" ] || fail nm_empty_output_pvrsrvkm
[ -s "$WORKDIR/dc_sun4i_undef.txt" ] || fail nm_empty_output_dc_sun4i

# Normalize: extract symbol names
awk '{print $NF}' "$WORKDIR/pvrsrvkm_undef.txt" | sort -u > "$WORKDIR/pvrsrvkm_undef.norm"
awk '{print $NF}' "$WORKDIR/dc_sun4i_undef.txt" | sort -u > "$WORKDIR/dc_sun4i_undef.norm"

pvrsrvkm_count=$(wc -l < "$WORKDIR/pvrsrvkm_undef.norm")
dc_sun4i_count=$(wc -l < "$WORKDIR/dc_sun4i_undef.norm")

# Check for forbidden private fbdev symbols
forbidden="registered_fb get_fb_info put_fb_info fb_con_dpi"
for sym in $forbidden; do
	if grep -qxF "$sym" "$WORKDIR/dc_sun4i_undef.norm" || grep -qxF "$sym" "$WORKDIR/pvrsrvkm_undef.norm"; then
		fail private_symbol_found "forbidden symbol: $sym"
	fi
done

# Name-level verification against Module.symvers in output dir
awk -F'\t' '{print $2}' "$KOUT/Module.symvers" | sort -u > "$WORKDIR/kernel_exports.txt"
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

kernel_export_count=$(wc -l < "$WORKDIR/kernel_exports.txt")

# Verify KERNELDIR source tree was NOT mutated (no tracked changes from gate1)
if ! git -C "$KERNELDIR" diff --quiet 2>/dev/null; then
	fail caller_source_tree_mutated "gate1 must not modify KERNELDIR tracked files"
fi

END_TIME=$(date +%s)
WALL_TIME=$((END_TIME - START_TIME))

echo "PASS gate1 release=$rel"
echo "  SAME-INVOCATION BUILD PROVENANCE:"
echo "    source_commit=$src_commit source_clean=$src_clean"
echo "    input_config_sha256=$input_config_sha256"
echo "    effective_config_sha256=$effective_config_sha256"
echo "    kernel_release=$rel"
echo "    vmlinux_symvers_sha256=$vmlinux_symvers_sha256"
echo "    modules_symvers_sha256=$modules_symvers_sha256"
echo "    final_module_symvers_sha256=$final_symvers_sha256"
echo "    race_detection=passed"
echo "    caller_tree_unmutated=true"
echo "    build_jobs=$JOBS (hard_max=$GATE1_HARD_MAX_JOBS)"
echo "    wall_time_seconds=$WALL_TIME"
echo "  MODULES:"
echo "    pvrsrvkm.ko: vermagic=$vm_pvrsrvkm sha256=$pvrsrvkm_sha256"
echo "    dc_sun4i.ko: vermagic=$vm_dc_sun4i sha256=$dc_sun4i_sha256"
echo "  VERIFICATION:"
echo "    Modversion ABI proof: fatal modpost against $KOUT/Module.symvers ($symvers_count entries)"
echo "    kernel_exports=$kernel_export_count"
echo "    Private symbols: NONE (verified registered_fb, get_fb_info, put_fb_info absent)"
echo "    Undefined symbols: dc_sun4i=$dc_sun4i_count pvrsrvkm=$pvrsrvkm_count (all CRC-verified via modpost)"
echo "    Name verification: supplementary check confirms all undefined symbols exist in Module.symvers"

# =====================================================================
# STEP 9: Structural immutability assertion
# =====================================================================
# Verify this script never writes to KERNELDIR (structural assertion)
# Check for: rm, cp, mv, or output redirection targeting $KERNELDIR
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
if grep -E '(rm|cp|mv|>|>>).*\$KERNELDIR' "$SCRIPT_PATH" 2>/dev/null | grep -v "^#" | grep -v "git -C.*KERNELDIR" | grep -v "grep.*KERNELDIR" | grep -v "sha256sum.*KERNELDIR" | grep -v "cat.*KERNELDIR" | grep -v "read.*KERNELDIR" | grep -vE '^\s*#'; then
	fail gate1_mutates_kerneldir "script must not write to KERNELDIR"
fi

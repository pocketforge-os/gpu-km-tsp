#!/bin/bash
# Gate 4 (bead tsp-71fdd65791d8498f4d78): DC backend mutual exclusivity validation.
# Verifies that the Makefile rejects conflicting DC backend selections.
# Usage: tests/gate4-dc-backend-exclusivity.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$HERE/Makefile"
fail() { echo "FAIL gate4 reason=$1 ${2:-}"; exit 1; }

# Check Makefile has mutual exclusivity checks
grep -q "Conflicting DC backend selection" "$MAKEFILE" || fail missing_conflict_check

# Test 1: PVR_HEADLESS_NO_DC=1 with PVR_DC_NULL=1 should conflict
OUTPUT=$(make -C "$HERE" -n PVR_SYSTEM=sunxi_a133 PVR_HEADLESS_NO_DC=1 PVR_DC_NULL=1 2>&1 || true)
if echo "$OUTPUT" | grep -q "mutually exclusive"; then
    echo "PASS: PVR_HEADLESS_NO_DC=1 + PVR_DC_NULL=1 correctly rejected"
else
    fail test1_no_rejection
fi

# Test 2: PVR_HEADLESS_NO_DC=1 with PVR_DC_SUN4I=1 should conflict
OUTPUT=$(make -C "$HERE" -n PVR_SYSTEM=sunxi_a133 PVR_HEADLESS_NO_DC=1 PVR_DC_SUN4I=1 2>&1 || true)
if echo "$OUTPUT" | grep -q "mutually exclusive"; then
    echo "PASS: PVR_HEADLESS_NO_DC=1 + PVR_DC_SUN4I=1 correctly rejected"
else
    fail test2_no_rejection
fi

# Test 3: PVR_DC_NULL=1 with PVR_DC_SUN4I=1 should conflict
OUTPUT=$(make -C "$HERE" -n PVR_SYSTEM=sunxi_a133 PVR_DC_NULL=1 PVR_DC_SUN4I=1 2>&1 || true)
if echo "$OUTPUT" | grep -q "mutually exclusive"; then
    echo "PASS: PVR_DC_NULL=1 + PVR_DC_SUN4I=1 correctly rejected"
else
    fail test3_no_rejection
fi

# Test 4: PVR_DC_SUN4I=1 alone should be accepted
OUTPUT=$(make -C "$HERE" -n PVR_SYSTEM=sunxi_a133 PVR_DC_SUN4I=1 2>&1 || true)
if echo "$OUTPUT" | grep -q "mutually exclusive"; then
    fail test4_false_positive
else
    echo "PASS: PVR_DC_SUN4I=1 alone correctly accepted"
fi

# Test 5: PVR_DC_NULL=1 alone should be accepted
OUTPUT=$(make -C "$HERE" -n PVR_SYSTEM=sunxi_a133 PVR_DC_NULL=1 2>&1 || true)
if echo "$OUTPUT" | grep -q "mutually exclusive"; then
    fail test5_false_positive
else
    echo "PASS: PVR_DC_NULL=1 alone correctly accepted"
fi

echo "PASS gate4 DC backend mutual exclusivity validated"

#!/bin/bash
# test-dcgetinfo-layout.sh
# Hermetic test for PVRSRV_BRIDGE_OUT_DCGETINFO struct layout
# Verifies the 72-byte ABI is correct (DC_DISPLAY_INFO=68 + eError=4)
#
# This script:
# - Compiles the layout test with production img_types.h
# - Runs the test and captures the exit code
# - Cleans up the binary regardless of success/failure
# - Reports results deterministically

set -uo pipefail  # Note: -e intentionally omitted to handle test failures gracefully

HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_SRC="$HERE/test-dcgetinfo-layout.c"
TEST_BIN="$HERE/test-dcgetinfo-layout"

# Cleanup function to ensure binary is removed
cleanup() {
    if [ -f "$TEST_BIN" ]; then
        rm -f "$TEST_BIN"
    fi
}

# Register cleanup trap to run on EXIT (covers all exit paths)
trap cleanup EXIT

echo "=== DCGETINFO Layout Test ==="
echo ""

# Check source exists
if [ ! -f "$TEST_SRC" ]; then
    echo "FAIL: test source not found: $TEST_SRC"
    exit 1
fi

# Compile the test
echo "Compiling test..."
if ! gcc -I"$HERE/../include" -o "$TEST_BIN" "$TEST_SRC"; then
    echo "FAIL: compilation failed"
    exit 1
fi
echo "Compilation successful."
echo ""

# Run the test and capture exit code
echo "Running test..."
echo ""
"$TEST_BIN"
exit_code=$?

# Report results
echo ""
if [ $exit_code -eq 0 ]; then
    echo "=== TEST PASSED ==="
    echo "The KM struct PVRSRV_BRIDGE_OUT_DCGETINFO is correctly 72 bytes."
    echo "eError is at offset 68, matching the UM ABI."
    echo "The trace's 'expected_out_size=68' was a layout tool bug, not a KM issue."
else
    echo "=== TEST FAILED ==="
    echo "Exit code: $exit_code"
    echo "Layout mismatch detected. The ABI may have changed."
fi

exit $exit_code

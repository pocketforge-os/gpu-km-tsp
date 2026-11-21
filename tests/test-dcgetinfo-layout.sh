#!/bin/bash
# test-dcgetinfo-layout.sh
# Hermetic test for PVRSRV_BRIDGE_OUT_DCGETINFO struct layout
# Verifies the 72-byte ABI is correct (DC_DISPLAY_INFO=68 + eError=4)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_SRC="$HERE/test-dcgetinfo-layout.c"
TEST_BIN="$HERE/test-dcgetinfo-layout"

echo "=== DCGETINFO Layout Test ==="
echo ""

# Compile the test
if [ ! -f "$TEST_SRC" ]; then
    echo "FAIL: test source not found: $TEST_SRC"
    exit 1
fi

echo "Compiling test..."
gcc -o "$TEST_BIN" "$TEST_SRC" || {
    echo "FAIL: compilation failed"
    exit 1
}
echo "Compilation successful."
echo ""

# Run the test
echo "Running test..."
echo ""
"$TEST_BIN"
exit_code=$?

# Cleanup
rm -f "$TEST_BIN"

if [ $exit_code -eq 0 ]; then
    echo ""
    echo "=== TEST PASSED ==="
    echo "The KM struct PVRSRV_BRIDGE_OUT_DCGETINFO is correctly 72 bytes."
    echo "eError is at offset 68, matching the UM ABI."
    echo "The trace's 'expected_out_size=68' was a layout tool bug, not a KM issue."
else
    echo ""
    echo "=== TEST FAILED ==="
fi

exit $exit_code

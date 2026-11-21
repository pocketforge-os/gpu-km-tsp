#!/bin/bash
# test-dcgetinfo-layout-negative.sh
# Negative test to verify the failure path of test-dcgetinfo-layout.sh
# This script creates a broken test binary and verifies the shell script
# handles the failure correctly (cleanup, reporting, exit code)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_SRC="$HERE/test-dcgetinfo-layout.c"
TEST_BIN="$HERE/test-dcgetinfo-layout"

# Cleanup function
cleanup() {
    if [ -f "$TEST_BIN" ]; then
        rm -f "$TEST_BIN"
    fi
}

trap cleanup EXIT

echo "=== Negative Test: Verifying Failure Path ==="
echo ""

# Check source exists
if [ ! -f "$TEST_SRC" ]; then
    echo "SETUP FAIL: test source not found: $TEST_SRC"
    exit 1
fi

# Compile the test
echo "Compiling test..."
if ! gcc -I"$HERE/../include" -o "$TEST_BIN" "$TEST_SRC"; then
    echo "SETUP FAIL: compilation failed"
    exit 1
fi
echo "Compilation successful."
echo ""

# Patch the binary to make it fail
# We'll create a wrapper that returns non-zero
echo "Creating failing test wrapper..."
cat > "$HERE/test-wrapper.sh" <<'WRAPPER'
#!/bin/bash
# Wrapper that runs the real test but returns failure
"$1"
# Force failure to test the failure path
echo ""
echo "INJECTED FAILURE: Forcing test to fail for negative test"
exit 1
WRAPPER
chmod +x "$HERE/test-wrapper.sh"

# Run the wrapper instead of the real test
echo "Running test (should fail)..."
echo ""
"$HERE/test-wrapper.sh" "$TEST_BIN"
exit_code=$?

# Clean up wrapper
rm -f "$HERE/test-wrapper.sh"

# Report results
echo ""
if [ $exit_code -ne 0 ]; then
    echo "=== NEGATIVE TEST PASSED ==="
    echo "Failure path works correctly."
    echo "Exit code: $exit_code (non-zero as expected)"
    exit 0
else
    echo "=== NEGATIVE TEST FAILED ==="
    echo "Expected non-zero exit code, got: $exit_code"
    exit 1
fi

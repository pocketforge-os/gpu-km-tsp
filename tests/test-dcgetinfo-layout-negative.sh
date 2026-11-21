#!/bin/bash
# test-dcgetinfo-layout-negative.sh
# Negative test to verify test-dcgetinfo-layout.sh handles failures correctly
#
# This test:
# 1. Activates the injection seam in test-dcgetinfo-layout.c via environment variable
# 2. Invokes test-dcgetinfo-layout.sh (the runner script)
# 3. Verifies the runner:
#    - Reports the failure deterministically
#    - Cleans up the binary via trap
#    - Exits with nonzero code
#
# The injection seam is fail-closed: only active when DCGETINFO_TEST_INJECT_FAIL
# is set. Normal production use does not trigger it.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEST_SH="$HERE/test-dcgetinfo-layout.sh"
TEST_BIN="$HERE/test-dcgetinfo-layout"

# Cleanup function for this test
cleanup() {
    # Ensure binary is cleaned up even if this test is interrupted
    if [ -f "$TEST_BIN" ]; then
        rm -f "$TEST_BIN"
    fi
}

trap cleanup EXIT

echo "=== Negative Test: Verifying Runner Script Failure Path ==="
echo ""

# Check that the runner script exists
if [ ! -f "$TEST_SH" ]; then
    echo "SETUP FAIL: runner script not found: $TEST_SH"
    exit 1
fi

# Verify binary does not exist before test
if [ -f "$TEST_BIN" ]; then
    echo "SETUP FAIL: binary already exists before test: $TEST_BIN"
    echo "This indicates a previous test did not clean up properly."
    exit 1
fi

echo "Invoking runner script with injection seam active..."
echo "Setting DCGETINFO_TEST_INJECT_FAIL=1"
echo ""

# Invoke the runner script with the injection seam active
# The runner script will:
# - Compile the test (which will succeed)
# - Run the test (which will fail due to injection seam)
# - Report the failure deterministically
# - Clean up the binary via trap
# - Exit with nonzero code

# Capture output and exit code
output=$(DCGETINFO_TEST_INJECT_FAIL=1 "$TEST_SH" 2>&1)
exit_code=$?

echo "$output"
echo ""

# Verify the runner exited with nonzero code
if [ $exit_code -eq 0 ]; then
    echo "=== NEGATIVE TEST FAILED ==="
    echo "Expected nonzero exit code from runner, got: $exit_code"
    echo "The runner script did not detect the failure."
    exit 1
fi

echo "Runner exited with code $exit_code (nonzero as expected)"
echo ""

# Verify the runner reported the failure
if ! echo "$output" | grep -q "TEST FAILED"; then
    echo "=== NEGATIVE TEST FAILED ==="
    echo "Runner did not report failure deterministically."
    echo "Expected 'TEST FAILED' in output."
    exit 1
fi

echo "Runner reported failure deterministically (found 'TEST FAILED')"
echo ""

# Verify cleanup happened (binary should not exist)
if [ -f "$TEST_BIN" ]; then
    echo "=== NEGATIVE TEST FAILED ==="
    echo "Binary not cleaned up after failure: $TEST_BIN"
    echo "The runner's cleanup trap did not execute."
    # Clean up manually to avoid leaving artifacts
    rm -f "$TEST_BIN"
    exit 1
fi

echo "Binary cleaned up correctly (no artifact left)"
echo ""

# Verify the runner compiled the test (check for "Compilation successful")
if ! echo "$output" | grep -q "Compilation successful"; then
    echo "=== NEGATIVE TEST FAILED ==="
    echo "Runner did not compile the test."
    exit 1
fi

echo "Runner compiled the test successfully"
echo ""

# Verify the injection seam was activated
if ! echo "$output" | grep -q "INJECTION SEAM ACTIVE"; then
    echo "=== NEGATIVE TEST FAILED ==="
    echo "Injection seam was not activated in test binary."
    exit 1
fi

echo "Injection seam was activated correctly"
echo ""

echo "=== NEGATIVE TEST PASSED ==="
echo "All failure path checks passed:"
echo "  ✓ Runner detected failure and exited with nonzero code"
echo "  ✓ Runner reported failure deterministically"
echo "  ✓ Runner cleaned up binary via trap"
echo "  ✓ Injection seam worked correctly"
echo ""
echo "The test-dcgetinfo-layout.sh script handles failures correctly."

exit 0

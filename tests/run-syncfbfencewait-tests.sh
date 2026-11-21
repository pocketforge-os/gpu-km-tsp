#!/bin/bash
# Test runner for SYNCFBFENCEWAIT parser hermetic fixtures.
# Verifies all 4 review findings and accepted r6 behavior.
#
# Usage: bash tests/run-syncfbfencewait-tests.sh
# Exit 0 if all pass, nonzero otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSER="$SCRIPT_DIR/rca-syncfbfencewait-poll.sh"
FIXDIR="$SCRIPT_DIR/fixtures/syncfbfencewait"

pass=0
fail=0
total=0

run_test() {
    local name="$1" fixture_dir="$2" expect_exit="$3" expect_disposition="$4"
    shift 4
    # Remaining args: key=value assertions on stdout
    local -a assertions=("$@")

    total=$((total + 1))
    local trace="$fixture_dir/trace-summary.txt"
    local output="" rc=0
    output=$(bash "$PARSER" "$trace" 2>&1) || rc=$?

    local ok=1
    local diagnostics=""

    # Check exit code
    if [ "$rc" -ne "$expect_exit" ]; then
        diagnostics+="  FAIL: expected exit=$expect_exit got exit=$rc\n"
        ok=0
    fi

    # Check disposition
    local got_disp
    got_disp=$(printf '%s\n' "$output" | grep "^disposition=" | tail -n 1 | cut -d= -f2)
    if [ "$got_disp" != "$expect_disposition" ]; then
        diagnostics+="  FAIL: expected disposition=$expect_disposition got disposition=$got_disp\n"
        ok=0
    fi

    # Check additional assertions (key=value in stdout)
    for assertion in "${assertions[@]}"; do
        local key="${assertion%%=*}"
        local expected_val="${assertion#*=}"
        local got_val
        got_val=$(printf '%s\n' "$output" | grep "^${key}=" | tail -n 1 | cut -d= -f2-)
        if [ "$got_val" != "$expected_val" ]; then
            diagnostics+="  FAIL: expected $key=$expected_val got $key=$got_val\n"
            ok=0
        fi
    done

    if [ "$ok" -eq 1 ]; then
        echo "PASS: $name"
        pass=$((pass + 1))
    else
        echo "FAIL: $name"
        printf '%b' "$diagnostics"
        echo "  --- output ---"
        printf '%s\n' "$output" | sed 's/^/  /'
        echo "  --- end ---"
        fail=$((fail + 1))
    fi
}

echo "=== SYNCFBFENCEWAIT parser hermetic tests ==="
echo ""

# --- Finding #1: full 64-bit handle identity ---
# distinct-64bit-handles: two handles sharing low byte 0x11 but different upper bytes
# Must produce 2 separate clusters, both expected_polling
run_test "distinct-64bit-handles: 2 clusters, not aliased" \
    "$FIXDIR/distinct-64bit-handles" \
    0 "expected_polling" \
    "total_timeout_returns=4"

# Verify the output contains two distinct handle lines
output=$(bash "$PARSER" "$FIXDIR/distinct-64bit-handles/trace-summary.txt" 2>&1)
total=$((total + 1))
handle_a=$(printf '%s\n' "$output" | grep -c "handle=0xaa00000000000011" || true)
handle_b=$(printf '%s\n' "$output" | grep -c "handle=0xbb00000000000011" || true)
if [ "$handle_a" -eq 1 ] && [ "$handle_b" -eq 1 ]; then
    echo "PASS: distinct-64bit-handles: full 64-bit identity (aa/bb distinct)"
    pass=$((pass + 1))
else
    echo "FAIL: distinct-64bit-handles: expected handle=0xaa00000000000011 and handle=0xbb00000000000011"
    echo "  got: handle_a=$handle_a handle_b=$handle_b"
    fail=$((fail + 1))
fi

# --- Finding #2: exact rule enforcement ---

# 2a: earlier OK then TIMEOUT -> stuck (final != OK)
run_test "earlier-ok-then-timeout: final is TIMEOUT -> stuck" \
    "$FIXDIR/earlier-ok-then-timeout" \
    1 "stuck_fence" \
    "total_timeout_returns=1"

# 2b: nonzero timeout with OK -> stuck (timeout!=0 violation)
run_test "nonzero-timeout-ok: nonzero timeout -> stuck" \
    "$FIXDIR/nonzero-timeout-ok" \
    1 "stuck_fence" \
    "total_timeout_returns=0"

# 2c: stuck with all TIMEOUT returns (no zero TIMEOUT count issue)
run_test "stuck-no-final-ok: all TIMEOUT -> stuck" \
    "$FIXDIR/stuck-no-final-ok" \
    1 "stuck_fence" \
    "total_timeout_returns=3"

# --- Finding #3: no-match with pipefail ---
run_test "no-fences: valid empty trace -> no_fences exit 0" \
    "$FIXDIR/no-fences" \
    0 "no_fences"

# --- Finding #4: fail closed on malformed ---

# 4a: unmatched BEFORE
run_test "unmatched-before: missing AFTER -> malformed exit 1" \
    "$FIXDIR/unmatched-before" \
    1 "malformed"

# 4b: truncated record
run_test "truncated-record: short in_hex -> malformed exit 1" \
    "$FIXDIR/truncated-record" \
    1 "malformed"

# --- Preserved r6 behavior ---
run_test "r6-mimic: 9 TIMEOUTs, 3 clusters + 3 OK-only -> expected_polling" \
    "$FIXDIR/r6-mimic" \
    0 "expected_polling" \
    "total_timeout_returns=9"

# --- Live r6 evidence (if available) ---
LIVE_R6_DIR="/home/matt/recovery/gpu16/runs/gfx7-g1c-r6x"
if [ -f "$LIVE_R6_DIR/trace-summary.txt" ] && [ -f "$LIVE_R6_DIR/syscall-trace-A.txt" ]; then
    run_test "live r6 evidence: 9 TIMEOUTs -> expected_polling" \
        "$LIVE_R6_DIR" \
        0 "expected_polling" \
        "total_timeout_returns=9"
else
    echo "SKIP: live r6 evidence not available at $LIVE_R6_DIR"
fi

echo ""
echo "=== Results: $pass passed, $fail failed, $total total ==="

if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0

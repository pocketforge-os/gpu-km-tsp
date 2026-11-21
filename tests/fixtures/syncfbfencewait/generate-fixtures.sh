#!/bin/bash
# Generate hermetic syscall-trace fixtures for SYNCFBFENCEWAIT parser tests.
# Run from repo root: bash tests/fixtures/syncfbfencewait/generate-fixtures.sh
set -euo pipefail

FIXDIR="$(cd "$(dirname "$0")" && pwd)"

# Helper: emit a BEFORE line
# Usage: before_line <seq> <handle_bytes_hex_16chars> <timeout_hex_8chars>
before_line() {
    local seq="$1" handle="$2" timeout="$3"
    echo "pid=100 function=ioctl phase=before fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 in_hex=${handle}${timeout}"
}

# Helper: emit an AFTER line
# Usage: after_line <seq> <eerr_hex_8chars>
after_line() {
    local seq="$1" eerr="$2"
    echo "pid=100 function=ioctl phase=after fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 out_hex=${eerr}"
}

OK="00000000"
TIMEOUT="09000000"
ZERO_T="00000000"
NZ_T="64000000"  # timeout=100 in LE

# ============================================================
# 1. r6-mimic: 3 polling clusters + 3 OK-only = 9 TIMEOUTs
# ============================================================
{
    seq=1
    # Handle 0x0b: 4 TIMEOUTs then OK
    for _ in 1 2 3 4; do before_line $seq "0b0000000000000000" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
    before_line $seq "0b0000000000000000" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x0d: 3 TIMEOUTs then OK
    for _ in 1 2 3; do before_line $seq "0d00000000000000" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
    before_line $seq "0d00000000000000" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x0e: 2 TIMEOUTs then OK
    for _ in 1 2; do before_line $seq "0e00000000000000" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
    before_line $seq "0e00000000000000" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x0c: OK only
    before_line $seq "0c00000000000000" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x09: OK only
    before_line $seq "0900000000000000" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x07: OK only
    before_line $seq "0700000000000000" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
} > "$FIXDIR/r6-mimic/syscall-trace-A.txt"
touch "$FIXDIR/r6-mimic/trace-summary.txt"

# ============================================================
# 2. distinct-64bit-handles: same low byte 0x11, different upper bytes
#    Handle A: bytes [11 00 00 00 00 00 00 AA] -> canonical 0xAA00000000000011
#    Handle B: bytes [11 00 00 00 00 00 00 BB] -> canonical 0xBB00000000000011
#    Both: 2 TIMEOUTs then OK -> 2 clusters, both expected_polling
# ============================================================
{
    seq=1
    # Handle A (LE: 11 00 00 00 00 00 00 AA): 2 TIMEOUTs then OK
    for _ in 1 2; do before_line $seq "11000000000000aa" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
    before_line $seq "11000000000000aa" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle B (LE: 11 00 00 00 00 00 00 BB): 2 TIMEOUTs then OK
    for _ in 1 2; do before_line $seq "11000000000000bb" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
    before_line $seq "11000000000000bb" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
} > "$FIXDIR/distinct-64bit-handles/syscall-trace-A.txt"
touch "$FIXDIR/distinct-64bit-handles/trace-summary.txt"

# ============================================================
# 3. earlier-ok-then-timeout: OK then TIMEOUT on same handle
#    Final result is TIMEOUT -> stuck_fence
# ============================================================
{
    seq=1
    before_line $seq "0f00000000000000" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    before_line $seq "0f00000000000000" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1))
} > "$FIXDIR/earlier-ok-then-timeout/syscall-trace-A.txt"
touch "$FIXDIR/earlier-ok-then-timeout/trace-summary.txt"

# ============================================================
# 4. nonzero-timeout-ok: nonzero timeout with OK result
#    Violates "every timeout must be 0" -> stuck_fence
# ============================================================
{
    seq=1
    before_line $seq "1000000000000000" "$NZ_T"; after_line $seq "$OK"; seq=$((seq+1))
} > "$FIXDIR/nonzero-timeout-ok/syscall-trace-A.txt"
touch "$FIXDIR/nonzero-timeout-ok/trace-summary.txt"

# ============================================================
# 5. stuck-no-final-ok: all timeout=0 but no OK (all TIMEOUT)
#    Final result is TIMEOUT -> stuck_fence
#    Also tests: stuck cluster with only TIMEOUT returns (no zero-TIMEOUT-count issue)
# ============================================================
{
    seq=1
    for _ in 1 2 3; do before_line $seq "1200000000000000" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
} > "$FIXDIR/stuck-no-final-ok/syscall-trace-A.txt"
touch "$FIXDIR/stuck-no-final-ok/trace-summary.txt"

# ============================================================
# 6. no-fences: no bridge calls at all
# ============================================================
{
    echo "pid=200 function=ioctl phase=before fd=5 bridge_seq=1 bridge_id=10 bridge_func_id=3 in_size=8 out_size=4 in_hex=0000000000000000"
    echo "pid=200 function=ioctl phase=after fd=5 bridge_seq=1 bridge_id=10 bridge_func_id=3 in_size=8 out_size=4 out_hex=00000000"
} > "$FIXDIR/no-fences/syscall-trace-A.txt"
touch "$FIXDIR/no-fences/trace-summary.txt"

# ============================================================
# 7. unmatched-before: BEFORE without corresponding AFTER
# ============================================================
{
    seq=1
    before_line $seq "1300000000000000" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1))
    # This BEFORE has no AFTER
    before_line $seq "1300000000000000" "$ZERO_T"
} > "$FIXDIR/unmatched-before/syscall-trace-A.txt"
touch "$FIXDIR/unmatched-before/trace-summary.txt"

# ============================================================
# 8. truncated-record: in_hex too short for full handle+timeout
# ============================================================
{
    seq=1
    # Valid record first
    before_line $seq "1400000000000000" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Truncated: only 10 hex chars instead of 24
    echo "pid=100 function=ioctl phase=before fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 in_hex=1400000000"
} > "$FIXDIR/truncated-record/syscall-trace-A.txt"
touch "$FIXDIR/truncated-record/trace-summary.txt"

echo "Fixtures generated in $FIXDIR"
for d in "$FIXDIR"/*/; do
    name=$(basename "$d")
    lines=$(wc -l < "$d/syscall-trace-A.txt")
    echo "  $name: $lines lines"
done

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

# Helper: generate 16-char handle from byte value (e.g., "0b" -> "0b00000000000000")
make_handle() {
    local byte="$1"
    printf '%s%014d' "$byte" 0
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
    for _ in 1 2 3 4; do before_line $seq "$(make_handle 0b)" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
    before_line $seq "$(make_handle 0b)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x0d: 3 TIMEOUTs then OK
    for _ in 1 2 3; do before_line $seq "$(make_handle 0d)" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
    before_line $seq "$(make_handle 0d)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x0e: 2 TIMEOUTs then OK
    for _ in 1 2; do before_line $seq "$(make_handle 0e)" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
    before_line $seq "$(make_handle 0e)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x0c: OK only
    before_line $seq "$(make_handle 0c)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x09: OK only
    before_line $seq "$(make_handle 09)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Handle 0x07: OK only
    before_line $seq "$(make_handle 07)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
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
    before_line $seq "$(make_handle 0f)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    before_line $seq "$(make_handle 0f)" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1))
} > "$FIXDIR/earlier-ok-then-timeout/syscall-trace-A.txt"
touch "$FIXDIR/earlier-ok-then-timeout/trace-summary.txt"

# ============================================================
# 4. nonzero-timeout-ok: nonzero timeout with OK result
#    Violates "every timeout must be 0" -> stuck_fence
# ============================================================
{
    seq=1
    before_line $seq "$(make_handle 10)" "$NZ_T"; after_line $seq "$OK"; seq=$((seq+1))
} > "$FIXDIR/nonzero-timeout-ok/syscall-trace-A.txt"
touch "$FIXDIR/nonzero-timeout-ok/trace-summary.txt"

# ============================================================
# 5. stuck-no-final-ok: all timeout=0 but no OK (all TIMEOUT)
#    Final result is TIMEOUT -> stuck_fence
# ============================================================
{
    seq=1
    for _ in 1 2 3; do before_line $seq "$(make_handle 12)" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1)); done
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
    before_line $seq "$(make_handle 13)" "$ZERO_T"; after_line $seq "$TIMEOUT"; seq=$((seq+1))
    # This BEFORE has no AFTER
    before_line $seq "$(make_handle 13)" "$ZERO_T"
} > "$FIXDIR/unmatched-before/syscall-trace-A.txt"
touch "$FIXDIR/unmatched-before/trace-summary.txt"

# ============================================================
# 8. truncated-record: in_hex too short for full handle+timeout
# ============================================================
{
    seq=1
    # Valid record first
    before_line $seq "$(make_handle 14)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # Truncated: only 10 hex chars instead of 24
    echo "pid=100 function=ioctl phase=before fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 in_hex=1400000000"
} > "$FIXDIR/truncated-record/syscall-trace-A.txt"
touch "$FIXDIR/truncated-record/trace-summary.txt"

# ============================================================
# 9. unexpected-phase: phase="error" (not before/after)
# ============================================================
{
    seq=1
    before_line $seq "$(make_handle 15)" "$ZERO_T"; after_line $seq "$OK"; seq=$((seq+1))
    # phase=error will be rejected before payload is checked
    echo "pid=100 function=ioctl phase=error fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 in_hex=15000000000000000000000000"
} > "$FIXDIR/unexpected-phase/syscall-trace-A.txt"
touch "$FIXDIR/unexpected-phase/trace-summary.txt"

# ============================================================
# 10. nonnumeric-seq: bridge_seq="abc"
# ============================================================
{
    seq=1
    before_line $seq "$(make_handle 16)" "$ZERO_T"; after_line $seq "$OK"
    # bridge_seq=abc will be rejected before payload is checked
    echo "pid=100 function=ioctl phase=before fd=5 bridge_seq=abc bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 in_hex=16000000000000000000000000"
} > "$FIXDIR/nonnumeric-seq/syscall-trace-A.txt"
touch "$FIXDIR/nonnumeric-seq/trace-summary.txt"

# ============================================================
# 11. overlong-in-hex: in_hex has 26 chars (need exactly 24)
# ============================================================
{
    seq=1
    # 26 hex chars = 13 bytes (2 extra)
    echo "pid=100 function=ioctl phase=before fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 in_hex=00000000000000000000000000"
} > "$FIXDIR/overlong-in-hex/syscall-trace-A.txt"
touch "$FIXDIR/overlong-in-hex/trace-summary.txt"

# ============================================================
# 12. overlong-out-hex: out_hex has 10 chars (need exactly 8)
# ============================================================
{
    seq=1
    before_line $seq "$(make_handle 18)" "$ZERO_T"
    # 10 hex chars = 5 bytes (2 extra)
    echo "pid=100 function=ioctl phase=after fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 out_hex=0000000000"
} > "$FIXDIR/overlong-out-hex/syscall-trace-A.txt"
touch "$FIXDIR/overlong-out-hex/trace-summary.txt"

# ============================================================
# 13. odd-length-in-hex: in_hex has 23 chars (odd and != 24)
# ============================================================
{
    seq=1
    # 23 hex chars (odd number)
    echo "pid=100 function=ioctl phase=before fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 in_hex=00000000000000000000000"
} > "$FIXDIR/odd-length-in-hex/syscall-trace-A.txt"
touch "$FIXDIR/odd-length-in-hex/trace-summary.txt"

# ============================================================
# 14. odd-length-out-hex: out_hex has 7 chars (odd and != 8)
# ============================================================
{
    seq=1
    before_line $seq "$(make_handle 1a)" "$ZERO_T"
    # 7 hex chars (odd number)
    echo "pid=100 function=ioctl phase=after fd=5 bridge_seq=$seq bridge_id=24 bridge_func_id=5 in_size=12 out_size=4 out_hex=0000000"
} > "$FIXDIR/odd-length-out-hex/syscall-trace-A.txt"
touch "$FIXDIR/odd-length-out-hex/trace-summary.txt"

# ============================================================
# 15. unreadable-evidence: syscall-trace-A.txt exists but is not readable
# ============================================================
{
    seq=1
    before_line $seq "$(make_handle 1b)" "$ZERO_T"; after_line $seq "$OK"
} > "$FIXDIR/unreadable-evidence/syscall-trace-A.txt"
touch "$FIXDIR/unreadable-evidence/trace-summary.txt"
# Note: chmod is done at test time, not here, to avoid issues if run as root

echo "Fixtures generated in $FIXDIR"
for d in "$FIXDIR"/*/; do
    name=$(basename "$d")
    lines=$(wc -l < "$d/syscall-trace-A.txt")
    echo "  $name: $lines lines"
done

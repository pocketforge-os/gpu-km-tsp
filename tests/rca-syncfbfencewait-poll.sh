#!/bin/bash
# RCA parser/fixture for SYNCFBFENCEWAIT PVRSRV_ERROR_TIMEOUT classification.
# Determines whether TIMEOUT returns are expected UM non-blocking polling
# or a real unsignalled-fence defect.
#
# Usage: tests/rca-syncfbfencewait-poll.sh <trace-summary.txt>
# The companion syscall-trace-A.txt must be in the same directory.
#
# Classification rules (exact):
#   expected_polling cluster: EVERY wait has timeout=0 AND the FINAL wait has eerr=0 (OK).
#   stuck_fence cluster:      any wait has timeout!=0 OR the FINAL wait has eerr!=0.
#   Global: any stuck cluster -> disposition=stuck_fence (exit 1).
#           all expected, total_timeout_returns>0 -> disposition=expected_polling (exit 0).
#           all expected, total_timeout_returns==0 -> disposition=no_timeouts (exit 0).
#           no bridge calls at all -> disposition=no_fences (exit 0).
#
# Fail-closed: unmatched BEFORE/AFTER or malformed records -> disposition=malformed (exit 1).
# Malformed: unexpected phase, non-numeric bridge_seq, wrong-length payloads
#            (in_hex must be exactly 24 hex chars, out_hex exactly 8 hex chars),
#            wrong/missing/nonnumeric declared sizes (in_size must be 12 for BEFORE,
#            out_size must be 4 for AFTER).
# Read error: unreadable/missing evidence -> disposition=read_error (exit 1).
#
# IMG_HANDLE: full 64-bit little-endian decode from bridge struct bytes 0-7.
set -euo pipefail

TRACE="${1:-}"
[ -n "$TRACE" ] || { echo "usage: $0 <trace-summary.txt>" >&2; exit 2; }
[ -f "$TRACE" ] || { echo "file not found: $TRACE" >&2; exit 2; }

DIR=$(dirname "$TRACE")
SYSTRACE="$DIR/syscall-trace-A.txt"
[ -f "$SYSTRACE" ] || { echo "companion syscall trace not found: $SYSTRACE" >&2; exit 2; }

# --- temp directory with cleanup ---
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

records="$tmpdir/records"    # joined: seq handle_hex timeout eerr
b_seqs="$tmpdir/b_seqs"      # all BEFORE seq numbers
a_seqs="$tmpdir/a_seqs"      # all AFTER seq numbers
errors="$tmpdir/errors"      # malformed record diagnostics
touch "$records" "$b_seqs" "$a_seqs" "$errors"
malformed_count=0

# --- hex helpers ---
# Convert 2-char hex byte to decimal
h2d_byte() { printf '%d' "0x${1}"; }

# Validate hex string: only [0-9a-fA-F], non-empty
is_hex() {
    local s="$1"
    [ -n "$s" ] || return 1
    [[ "$s" =~ ^[0-9a-fA-F]+$ ]]
}

# Decode full 64-bit LE handle from chars 0-15 of in_hex.
# Returns canonical uppercase hex string (16 chars, big-endian display order).
decode_handle_64() {
    local hx="$1"
    local b0="${hx:0:2}" b1="${hx:2:2}" b2="${hx:4:2}" b3="${hx:6:2}"
    local b4="${hx:8:2}" b5="${hx:10:2}" b6="${hx:12:2}" b7="${hx:14:2}"
    # Canonical: reverse byte order (LE -> display)
    printf '%s%s%s%s%s%s%s%s' "$b7" "$b6" "$b5" "$b4" "$b3" "$b2" "$b1" "$b0"
}

# Decode 4-byte LE uint32 from 8 hex chars
decode_u32_le() {
    local hx="$1"
    local b0="${hx:0:2}" b1="${hx:2:2}" b2="${hx:4:2}" b3="${hx:6:2}"
    echo $(( $(h2d_byte "$b3") * 16777216 + $(h2d_byte "$b2") * 65536 + $(h2d_byte "$b1") * 256 + $(h2d_byte "$b0") ))
}

# --- extract field from trace line ---
# Usage: extract_field "field_name" "$line"
extract_field() {
    local fname="$1" line="$2"
    # Match " field_name=value" followed by space or end-of-line
    local val
    val=$(printf '%s' "$line" | sed -n "s/.* ${fname}=\([^ ]*\).*/\1/p")
    printf '%s' "$val"
}

# --- Phase 1: grep bridge lines safely ---
# Distinguish grep status 1 (no match) from status 2+ (read/usage error).
# Only status 1 produces no_fences; any other failure is read_error.
bridge_lines=""
grep_rc=0
bridge_lines=$(grep "bridge_id=24 bridge_func_id=5" "$SYSTRACE" 2>/dev/null) || grep_rc=$?

if [ "$grep_rc" -eq 1 ]; then
    echo "no SYNCFBFENCEWAIT bridge calls found in syscall trace"
    echo "disposition=no_fences"
    exit 0
elif [ "$grep_rc" -ne 0 ]; then
    echo "failed to read syscall trace: $SYSTRACE (grep exit=$grep_rc)" >&2
    echo "disposition=read_error"
    echo "reason=grep_failed_exit=$grep_rc"
    exit 1
fi

if [ -z "$bridge_lines" ]; then
    echo "no SYNCFBFENCEWAIT bridge calls found in syscall trace"
    echo "disposition=no_fences"
    exit 0
fi

# --- Phase 2: parse BEFORE/AFTER records ---
while IFS= read -r line; do
    [ -n "$line" ] || continue

    phase=$(extract_field "phase" "$line")
    seq=$(extract_field "bridge_seq" "$line")

    # Missing fields
    if [ -z "$phase" ] || [ -z "$seq" ]; then
        echo "MALFORMED: missing phase or bridge_seq" >> "$errors"
        malformed_count=$((malformed_count + 1))
        continue
    fi

    # bridge_seq must be a non-negative integer
    if ! [[ "$seq" =~ ^[0-9]+$ ]]; then
        echo "MALFORMED: non-numeric bridge_seq=$seq" >> "$errors"
        malformed_count=$((malformed_count + 1))
        continue
    fi

    # Phase must be exactly "before" or "after" (unexpected phase -> malformed)
    if [ "$phase" != "before" ] && [ "$phase" != "after" ]; then
        echo "MALFORMED: unexpected phase=$phase seq=$seq" >> "$errors"
        malformed_count=$((malformed_count + 1))
        continue
    fi

    if [ "$phase" = "before" ]; then
        echo "$seq" >> "$b_seqs"

        # Validate declared in_size (must be present, numeric, exactly 12)
        in_size=$(extract_field "in_size" "$line")
        if [ -z "$in_size" ]; then
            echo "MALFORMED before seq=$seq: missing in_size" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        if ! [[ "$in_size" =~ ^[0-9]+$ ]]; then
            echo "MALFORMED before seq=$seq: nonnumeric in_size=$in_size" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        if [ "$in_size" -ne 12 ]; then
            echo "MALFORMED before seq=$seq: in_size=$in_size (expected 12)" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi

        in_hex=$(extract_field "in_hex" "$line")
        if [ -z "$in_hex" ] || [ "$in_hex" = "-" ]; then
            echo "MALFORMED before seq=$seq: missing in_hex" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        if ! is_hex "$in_hex"; then
            echo "MALFORMED before seq=$seq: in_hex not hex: $in_hex" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        # Struct: 8 bytes handle + 4 bytes timeout = exactly 24 hex chars
        in_hex_len=${#in_hex}
        if [ "$in_hex_len" -ne 24 ]; then
            echo "MALFORMED before seq=$seq: in_hex wrong length ($in_hex_len chars, need exactly 24)" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        # Even length check (defense-in-depth; exact 24 already implies even)
        if [ $((in_hex_len % 2)) -ne 0 ]; then
            echo "MALFORMED before seq=$seq: in_hex odd length ($in_hex_len)" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        handle_hex=$(decode_handle_64 "$in_hex")
        timeout=$(decode_u32_le "${in_hex:16:8}")
        echo "$seq $handle_hex $timeout" >> "$tmpdir/before"

    elif [ "$phase" = "after" ]; then
        echo "$seq" >> "$a_seqs"

        # Validate declared out_size (must be present, numeric, exactly 4)
        out_size=$(extract_field "out_size" "$line")
        if [ -z "$out_size" ]; then
            echo "MALFORMED after seq=$seq: missing out_size" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        if ! [[ "$out_size" =~ ^[0-9]+$ ]]; then
            echo "MALFORMED after seq=$seq: nonnumeric out_size=$out_size" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        if [ "$out_size" -ne 4 ]; then
            echo "MALFORMED after seq=$seq: out_size=$out_size (expected 4)" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi

        out_hex=$(extract_field "out_hex" "$line")
        if [ -z "$out_hex" ] || [ "$out_hex" = "-" ]; then
            echo "MALFORMED after seq=$seq: missing out_hex" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        if ! is_hex "$out_hex"; then
            echo "MALFORMED after seq=$seq: out_hex not hex: $out_hex" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        # Struct: 4 bytes eError = exactly 8 hex chars
        out_hex_len=${#out_hex}
        if [ "$out_hex_len" -ne 8 ]; then
            echo "MALFORMED after seq=$seq: out_hex wrong length ($out_hex_len chars, need exactly 8)" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        # Even length check (defense-in-depth; exact 8 already implies even)
        if [ $((out_hex_len % 2)) -ne 0 ]; then
            echo "MALFORMED after seq=$seq: out_hex odd length ($out_hex_len)" >> "$errors"
            malformed_count=$((malformed_count + 1))
            continue
        fi
        eerr=$(decode_u32_le "${out_hex:0:8}")
        echo "$seq $eerr" >> "$tmpdir/after"
    fi
done <<< "$bridge_lines"

# --- Phase 3: fail closed on malformed records ---
if [ "$malformed_count" -gt 0 ]; then
    echo "malformed_records=$malformed_count"
    cat "$errors" >&2
    echo "disposition=malformed"
    echo "reason=malformed_records"
    exit 1
fi

# --- Phase 4: detect missing before/after files ---
if [ ! -f "$tmpdir/before" ] || [ ! -s "$tmpdir/before" ]; then
    if [ -s "$a_seqs" ]; then
        echo "disposition=malformed"
        echo "reason=after_without_before"
        exit 1
    fi
    echo "disposition=no_fences"
    exit 0
fi
if [ ! -f "$tmpdir/after" ] || [ ! -s "$tmpdir/after" ]; then
    echo "disposition=malformed"
    echo "reason=before_without_after"
    exit 1
fi

# --- Phase 5: join BEFORE/AFTER by seq, detect unmatched ---
# Sort both files by seq
sort -k1,1n "$tmpdir/before" > "$tmpdir/before_sorted"
sort -k1,1n "$tmpdir/after" > "$tmpdir/after_sorted"

# Join on seq (field 1)
join -j 1 "$tmpdir/before_sorted" "$tmpdir/after_sorted" > "$records" 2>/dev/null || true

# Check for unmatched BEFORE seqs
join -v 1 -j 1 "$tmpdir/before_sorted" "$tmpdir/after_sorted" > "$tmpdir/unmatched_b" 2>/dev/null || true
if [ -s "$tmpdir/unmatched_b" ]; then
    unmatched_b_count=$(wc -l < "$tmpdir/unmatched_b")
    echo "unmatched_before=$unmatched_b_count"
    echo "disposition=malformed"
    echo "reason=unmatched_before"
    exit 1
fi

# Check for unmatched AFTER seqs
join -v 2 -j 1 "$tmpdir/before_sorted" "$tmpdir/after_sorted" > "$tmpdir/unmatched_a" 2>/dev/null || true
if [ -s "$tmpdir/unmatched_a" ]; then
    unmatched_a_count=$(wc -l < "$tmpdir/unmatched_a")
    echo "unmatched_after=$unmatched_a_count"
    echo "disposition=malformed"
    echo "reason=unmatched_after"
    exit 1
fi

# Sort joined records by seq for chronological ordering
sort -k1,1n "$records" > "$tmpdir/joined_sorted"

if [ ! -s "$tmpdir/joined_sorted" ]; then
    echo "disposition=no_fences"
    exit 0
fi

# --- Phase 6: cluster by consecutive same-handle, classify ---
# records format: seq handle_hex timeout eerr
cluster_n=0
any_stuck=0
cur_handle=""
cluster_timeouts=0
cluster_total=0
cluster_all_zero_timeout=1
cluster_last_eerr=""
total_timeouts=0

flush_cluster() {
    if [ -n "$cur_handle" ]; then
        local disp="expected_polling"
        # expected_polling requires: ALL timeout=0 AND final eerr=0
        if [ "$cluster_all_zero_timeout" -ne 1 ] || [ "$cluster_last_eerr" != "0" ]; then
            disp="stuck_fence"
            any_stuck=1
        fi
        printf "cluster=%d handle=0x%s timeouts=%d total=%d disposition=%s\n" \
            "$cluster_n" "$cur_handle" "$cluster_timeouts" "$cluster_total" "$disp"
    fi
}

while read -r seq handle_hex timeout eerr; do
    [ -n "$seq" ] || continue

    if [ "$handle_hex" != "$cur_handle" ]; then
        flush_cluster
        cluster_n=$((cluster_n + 1))
        cur_handle="$handle_hex"
        cluster_timeouts=0
        cluster_total=0
        cluster_all_zero_timeout=1
        cluster_last_eerr=""
    fi

    cluster_total=$((cluster_total + 1))
    cluster_last_eerr="$eerr"

    # Count TIMEOUT returns (eerr=9)
    if [ "$eerr" -eq 9 ]; then
        cluster_timeouts=$((cluster_timeouts + 1))
        total_timeouts=$((total_timeouts + 1))
    fi

    # Nonzero timeout is a violation regardless of eerr (finding #2)
    if [ "$timeout" -ne 0 ]; then
        cluster_all_zero_timeout=0
    fi
done < "$tmpdir/joined_sorted"
flush_cluster

# --- Phase 7: global disposition ---
echo "---"
echo "total_timeout_returns=$total_timeouts"

if [ "$any_stuck" -ne 0 ]; then
    echo "disposition=stuck_fence"
    exit 1
elif [ "$total_timeouts" -gt 0 ]; then
    echo "disposition=expected_polling"
    exit 0
else
    echo "disposition=no_timeouts"
    exit 0
fi

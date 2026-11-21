#!/bin/bash
# RCA parser/fixture for SYNCFBFENCEWAIT PVRSRV_ERROR_TIMEOUT classification.
# Determines whether TIMEOUT returns are expected UM non-blocking polling
# or a real unsignalled-fence defect.
#
# Usage: tests/rca-syncfbfencewait-poll.sh <trace-summary.txt>
# The companion syscall-trace-A.txt must be in the same directory.
set -euo pipefail

TRACE="${1:-}"
[ -n "$TRACE" ] || { echo "usage: $0 <trace-summary.txt>" >&2; exit 2; }
[ -f "$TRACE" ] || { echo "file not found: $TRACE" >&2; exit 2; }

DIR=$(dirname "$TRACE")
SYSTRACE="$DIR/syscall-trace-A.txt"
[ -f "$SYSTRACE" ] || { echo "companion syscall trace not found" >&2; exit 2; }

# h2d HEX: convert hex string to decimal using printf
h2d() { printf '%d' "0x$1"; }

# Process syscall trace to produce joined table: seq handle timeout eerr
# Extract BEFORE and AFTER lines, match by seq
tmp=$(mktemp)
trap "rm -f $tmp" EXIT

# BEFORE: extract seq, handle (byte 0 of in_hex), timeout (bytes 8-11 LE of in_hex)
grep "bridge_id=24 bridge_func_id=5" "$SYSTRACE" | \
while IFS= read -r line; do
    phase=$(echo "$line" | sed -n 's/.* phase=\([^ ]*\) .*/\1/p')
    seq=$(echo "$line" | sed -n 's/.* bridge_seq=\([^ ]*\) .*/\1/p')
    if [ "$phase" = "before" ]; then
        in_hex=$(echo "$line" | sed -n 's/.* in_hex=\([^ ]*\) .*/\1/p')
        [ -n "$in_hex" ] && [ "$in_hex" != "-" ] || continue
        handle=$(h2d "${in_hex:0:2}")
        # Timeout: bytes 8-11 LE (chars 16-23)
        b8=${in_hex:16:2}; b9=${in_hex:18:2}; b10=${in_hex:20:2}; b11=${in_hex:22:2}
        timeout=$(( $(h2d "$b11") * 16777216 + $(h2d "$b10") * 65536 + $(h2d "$b9") * 256 + $(h2d "$b8") ))
        echo "B $seq $handle $timeout"
    elif [ "$phase" = "after" ]; then
        out_hex=$(echo "$line" | sed -n 's/.* out_hex=\([^ ]*\) .*/\1/p')
        [ -n "$out_hex" ] && [ "$out_hex" != "-" ] || continue
        e0=${out_hex:0:2}; e1=${out_hex:2:2}; e2=${out_hex:4:2}; e3=${out_hex:6:2}
        eerr=$(( $(h2d "$e3") * 16777216 + $(h2d "$e2") * 65536 + $(h2d "$e1") * 256 + $(h2d "$e0") ))
        echo "A $seq $eerr"
    fi
done | sort -k2,2n > "$tmp"

# Join B and A records by seq
joined=$(awk '
/^B/ { handle[$2]=$3; timeout[$2]=$4; seqs[$2]=1 }
/^A/ { eerr[$2]=$3 }
END {
    for (s in seqs) {
        if (s in eerr) print s, handle[s], timeout[s], eerr[s]
    }
}' "$tmp" | sort -n)

if [ -z "$joined" ]; then
    echo "no SYNCFBFENCEWAIT calls decoded"
    echo "disposition=no_fences"
    exit 0
fi

# Cluster by consecutive same-handle, compute disposition
cluster_n=0
any_stuck=0
cur_handle=""
timeouts=0
total=0
has_ok=0
has_nz=0
total_timeouts=0

flush() {
    if [ -n "$cur_handle" ]; then
        disp="expected_polling"
        if [ "$has_ok" -eq 0 ] || [ "$has_nz" -ne 0 ]; then
            disp="stuck_fence"
            any_stuck=1
        fi
        printf "cluster=%d handle=0x%02x timeouts=%d total=%d disposition=%s\n" \
            "$cluster_n" "$cur_handle" "$timeouts" "$total" "$disp"
    fi
}

while read -r seq handle timeout eerr; do
    [ -z "$seq" ] && continue
    if [ "$handle" != "$cur_handle" ]; then
        flush
        cluster_n=$((cluster_n + 1))
        cur_handle=$handle
        timeouts=0; total=0; has_ok=0; has_nz=0
    fi
    total=$((total + 1))
    if [ "$eerr" -eq 9 ]; then
        timeouts=$((timeouts + 1))
        total_timeouts=$((total_timeouts + 1))
        [ "$timeout" -ne 0 ] && has_nz=1
    elif [ "$eerr" -eq 0 ]; then
        has_ok=1
    fi
done <<< "$joined"
flush

echo "---"
echo "total_timeout_returns=$total_timeouts"
if [ "$any_stuck" -eq 0 ] && [ "$total_timeouts" -gt 0 ]; then
    echo "disposition=expected_polling"
    exit 0
elif [ "$total_timeouts" -eq 0 ]; then
    echo "disposition=no_timeouts"
    exit 0
else
    echo "disposition=stuck_fence"
    exit 1
fi

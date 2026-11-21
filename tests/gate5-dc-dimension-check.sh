#!/bin/bash
# Gate 5 (bead tsp-71fdd65791d8498f4d78): ContextConfigureCheck dimension validation.
# Verifies that ContextConfigureCheck rejects either width OR height mismatch.
# Usage: tests/gate5-dc-dimension-check.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DC_FILE="$HERE/services/3rdparty/dc_sun4i/dc_sun4i.c"
fail() { echo "FAIL gate5 reason=$1 ${2:-}"; exit 1; }

# Check that the dimension check uses OR (||) not AND (&&)
# The pattern should be: if(psBuffer->ui32Width != psVar->xres || psBuffer->ui32Height != psVar->yres)
if grep -A1 "psBuffer->ui32Width.*psVar->xres" "$DC_FILE" | grep -q "||"; then
    echo "PASS: Dimension check uses OR (||) - rejects either width OR height mismatch"
else
    fail dimension_check_uses_and
fi

# Verify the exact pattern
if grep -q "psBuffer->ui32Width.*!=.*psVar->xres ||" "$DC_FILE"; then
    echo "PASS: Width mismatch check present with OR"
else
    fail width_check_missing
fi

if grep -A1 "psBuffer->ui32Width.*!=.*psVar->xres ||" "$DC_FILE" | grep -q "psBuffer->ui32Height.*!=.*psVar->yres"; then
    echo "PASS: Height mismatch check present with OR"
else
    fail height_check_missing
fi

# Verify error code
if grep -A3 "psBuffer->ui32Width.*!=.*psVar->xres ||" "$DC_FILE" | grep -q "PVRSRV_ERROR_DC_INVALID_BUFFER_DIMS"; then
    echo "PASS: Correct error code (PVRSRV_ERROR_DC_INVALID_BUFFER_DIMS)"
else
    fail wrong_error_code
fi

echo "PASS gate5 ContextConfigureCheck dimension validation"

#!/bin/bash
# Gate 6 (bead tsp-71fdd65791d8498f4d78): BufferAcquire unsupported mapping validation.
# Verifies that BufferAcquire checks for valid fix.smem_start and rejects unsupported mappings.
# Usage: tests/gate6-dc-buffer-acquire-validation.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DC_FILE="$HERE/services/3rdparty/dc_sun4i/dc_sun4i.c"
fail() { echo "FAIL gate6 reason=$1 ${2:-}"; exit 1; }

# Check that BufferAcquire uses fix.smem_start (not screen_base with vmalloc_to_page)
if grep -A20 "DC_SUN4I_BufferAcquire" "$DC_FILE" | grep -q "fix.smem_start"; then
    echo "PASS: BufferAcquire uses fix.smem_start"
else
    fail missing_fix_smem_start
fi

# Check that vmalloc_to_page is NOT used (Linux 7.2 drm_fbdev_dma uses direct DMA)
if grep "DC_SUN4I_BufferAcquire" -A50 "$DC_FILE" | grep -q "vmalloc_to_page"; then
    fail vmalloc_to_page_still_present
else
    echo "PASS: BufferAcquire does not use vmalloc_to_page (correct for Linux 7.2)"
fi

# Check that there's a validation for smem_start == 0
if grep -A30 "DC_SUN4I_BufferAcquire" "$DC_FILE" | grep -q "uiStartAddr == 0"; then
    echo "PASS: BufferAcquire validates smem_start != 0"
else
    fail missing_smem_start_validation
fi

# Check that PVRSRV_ERROR_NOT_SUPPORTED is returned for unsupported mappings
if grep -A30 "DC_SUN4I_BufferAcquire" "$DC_FILE" | grep -q "PVRSRV_ERROR_NOT_SUPPORTED"; then
    echo "PASS: BufferAcquire returns PVRSRV_ERROR_NOT_SUPPORTED for unsupported mappings"
else
    fail missing_not_supported_return
fi

# Check that DC_SUN4I_USE_SCREEN_BASE is NOT defined in Kbuild.mk
KBUILD_FILE="$HERE/services/3rdparty/dc_sun4i/Kbuild.mk"
if grep -q "DC_SUN4I_USE_SCREEN_BASE" "$KBUILD_FILE"; then
    fail screen_base_still_defined
else
    echo "PASS: DC_SUN4I_USE_SCREEN_BASE not defined (correct for Linux 7.2)"
fi

echo "PASS gate6 BufferAcquire unsupported mapping validation"

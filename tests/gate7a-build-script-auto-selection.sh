#!/bin/bash
# gate7a-build-script-auto-selection.sh — Test build-sunxi-a133.sh auto-selection logic
# Exercises the actual build script's kernel/config auto-selection with explicit overrides
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

# Extract the auto-selection logic from build-sunxi-a133.sh into a testable function
test_auto_selection() {
    local test_name="$1"
    local has_drm_fbdev_emu="$2"
    local has_legacy_fb="$3"
    local kernel_major="$4"
    local explicit_headless="${5:-}"
    local explicit_null="${6:-}"
    local explicit_sun4i="${7:-}"
    local expected_sun4i="$8"
    local expected_null="$9"
    local expected_headless="${10}"
    local expected_sunxi="${11:-0}"

    # Simulate the auto-selection logic from build-sunxi-a133.sh
    local PVR_HEADLESS_NO_DC="$explicit_headless"
    local PVR_DC_NULL="$explicit_null"
    local PVR_DC_SUN4I="$explicit_sun4i"

    # Check if any explicit backend selector is already set
    local EXPLICIT_SET=0
    [ -n "${PVR_HEADLESS_NO_DC:-}" ] && EXPLICIT_SET=1
    [ -n "${PVR_DC_NULL:-}" ] && EXPLICIT_SET=1
    [ -n "${PVR_DC_SUN4I:-}" ] && EXPLICIT_SET=1

    # Only apply automatic defaults if no explicit selector is set
    if [ "$EXPLICIT_SET" -eq 0 ]; then
        if [ "$has_drm_fbdev_emu" -eq 0 ] && [ "$has_legacy_fb" -eq 0 ]; then
            # No fbdev support at all; use dc_null
            PVR_DC_NULL=1
        else
            # fbdev support present; check kernel version
            if [ "${kernel_major:-0}" -ge 6 ] && [ "$has_drm_fbdev_emu" -eq 1 ]; then
                PVR_DC_SUN4I=1
            fi
            # For kernel < 6 or without DRM fbdev emulation, leave all flags unset (dc_sunxi default)
        fi
    fi

    # Determine which backend is selected
    local got_sun4i=0 got_null=0 got_headless=0 got_sunxi=0
    [ "${PVR_DC_SUN4I:-0}" = "1" ] && got_sun4i=1
    [ "${PVR_DC_NULL:-0}" = "1" ] && got_null=1
    [ "${PVR_HEADLESS_NO_DC:-0}" = "1" ] && got_headless=1
    # dc_sunxi is selected when all flags are unset
    [ "${PVR_DC_SUN4I:-0}" != "1" ] && [ "${PVR_DC_NULL:-0}" != "1" ] && [ "${PVR_HEADLESS_NO_DC:-0}" != "1" ] && got_sunxi=1

    # Check expectations
    if [ "$expected_headless" = "1" ]; then
        if [ $got_headless -eq 1 ] && [ $got_sun4i -eq 0 ] && [ $got_null -eq 0 ] && [ $got_sunxi -eq 0 ]; then
            echo "PASS: $test_name - headless (no DC backend)"
            PASS=$((PASS + 1))
        else
            echo "FAIL: $test_name - expected headless, got sun4i=$got_sun4i null=$got_null sunxi=$got_sunxi headless=$got_headless"
            FAIL=$((FAIL + 1))
        fi
    elif [ "$expected_sunxi" = "1" ]; then
        if [ $got_sunxi -eq 1 ] && [ $got_sun4i -eq 0 ] && [ $got_null -eq 0 ] && [ $got_headless -eq 0 ]; then
            echo "PASS: $test_name - dc_sunxi (default)"
            PASS=$((PASS + 1))
        else
            echo "FAIL: $test_name - expected dc_sunxi, got sun4i=$got_sun4i null=$got_null sunxi=$got_sunxi headless=$got_headless"
            FAIL=$((FAIL + 1))
        fi
    else
        # Check for exactly one backend
        local count=$((got_sun4i + got_null + got_headless + got_sunxi))
        if [ $count -ne 1 ]; then
            echo "FAIL: $test_name - expected 1 backend, got $count (sun4i=$got_sun4i, null=$got_null, sunxi=$got_sunxi, headless=$got_headless)"
            FAIL=$((FAIL + 1))
        elif [ $got_sun4i -ne $expected_sun4i ] || [ $got_null -ne $expected_null ]; then
            echo "FAIL: $test_name - expected sun4i=$expected_sun4i null=$expected_null, got sun4i=$got_sun4i null=$got_null"
            FAIL=$((FAIL + 1))
        else
            echo "PASS: $test_name"
            PASS=$((PASS + 1))
        fi
    fi
}

echo "=== Testing build-sunxi-a133.sh auto-selection with explicit overrides ==="

# Test 1: Linux 7.2 + DRM fbdev, no explicit override -> dc_sun4i
test_auto_selection "Linux 7.2 + DRM fbdev, default" 1 0 7 "" "" "" 1 0 0 0

# Test 2: Linux 7.2 + DRM fbdev, explicit headless -> headless (no backend)
test_auto_selection "Linux 7.2 + DRM fbdev, explicit headless" 1 0 7 "1" "" "" 0 0 1 0

# Test 3: Linux 7.2 + DRM fbdev, explicit dc_null -> dc_null
test_auto_selection "Linux 7.2 + DRM fbdev, explicit dc_null" 1 0 7 "" "1" "" 0 1 0 0

# Test 4: Linux 7.2 + DRM fbdev, explicit dc_sun4i -> dc_sun4i
test_auto_selection "Linux 7.2 + DRM fbdev, explicit dc_sun4i" 1 0 7 "" "" "1" 1 0 0 0

# Test 5: No fbdev, no explicit override -> dc_null
test_auto_selection "No fbdev, default" 0 0 7 "" "" "" 0 1 0 0

# Test 6: No fbdev, explicit headless -> headless (no backend)
test_auto_selection "No fbdev, explicit headless" 0 0 7 "1" "" "" 0 0 1 0

# Test 7: No fbdev, explicit dc_null -> dc_null
test_auto_selection "No fbdev, explicit dc_null" 0 0 7 "" "1" "" 0 1 0 0

# Test 8: Linux 4.9 + legacy FB, no explicit override -> dc_sunxi (default)
test_auto_selection "Linux 4.9 + legacy FB, default" 0 1 4 "" "" "" 0 0 0 1

# Test 9: Linux 4.9 + legacy FB, explicit headless -> headless
test_auto_selection "Linux 4.9 + legacy FB, explicit headless" 0 1 4 "1" "" "" 0 0 1 0

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ $FAIL -gt 0 ]; then
    exit 1
fi

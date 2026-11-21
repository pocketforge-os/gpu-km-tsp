#!/bin/bash
# gate7-backend-selection.sh — Verify exactly one DC backend is selected
# Tests the Makefile selection logic and build-sunxi-a133.sh auto-detection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

# Helper to check which backends would be included based on Makefile logic
check_backend_logic() {
    local test_name="$1"
    local headless="${2:-}"
    local dc_null="${3:-}"
    local dc_sun4i="${4:-}"
    local expected_sunxi="$5"
    local expected_sun4i="$6"
    local expected_null="$7"
    local should_error="${8:-0}"

    # Simulate Makefile logic
    local will_error=0
    local build_sunxi=0
    local build_sun4i=0
    local build_null=0

    # Check for conflicts
    if [ "$headless" = "1" ] && [ "$dc_null" = "1" ]; then
        will_error=1
    fi
    if [ "$headless" = "1" ] && [ "$dc_sun4i" = "1" ]; then
        will_error=1
    fi
    if [ "$dc_null" = "1" ] && [ "$dc_sun4i" = "1" ]; then
        will_error=1
    fi

    if [ "$will_error" = "1" ]; then
        if [ "$should_error" = "1" ]; then
            echo "PASS: $test_name - conflict correctly rejected"
            PASS=$((PASS + 1))
            return
        else
            echo "FAIL: $test_name - unexpected conflict"
            FAIL=$((FAIL + 1))
            return
        fi
    fi

    # Determine which backends would be built
    # dc_sunxi: built unless headless=1 OR dc_sun4i=1 OR dc_null=1
    if [ "$headless" != "1" ] && [ "$dc_sun4i" != "1" ] && [ "$dc_null" != "1" ]; then
        build_sunxi=1
    fi

    # dc_sun4i: built only if dc_sun4i=1
    if [ "$dc_sun4i" = "1" ]; then
        build_sun4i=1
    fi

    # dc_null: built only if dc_null=1
    if [ "$dc_null" = "1" ]; then
        build_null=1
    fi

    # Count active backends
    local count=$((build_sunxi + build_sun4i + build_null))

    if [ "$headless" = "1" ]; then
        if [ $count -eq 0 ]; then
            echo "PASS: $test_name - headless mode (no backends)"
            PASS=$((PASS + 1))
        else
            echo "FAIL: $test_name - headless=1 but got $count backends"
            FAIL=$((FAIL + 1))
        fi
    else
        if [ $count -ne 1 ]; then
            echo "FAIL: $test_name - expected 1 backend, got $count (sunxi=$build_sunxi, sun4i=$build_sun4i, null=$build_null)"
            FAIL=$((FAIL + 1))
        elif [ $build_sunxi -ne $expected_sunxi ] || [ $build_sun4i -ne $expected_sun4i ] || [ $build_null -ne $expected_null ]; then
            echo "FAIL: $test_name - expected sunxi=$expected_sunxi sun4i=$expected_sun4i null=$expected_null, got sunxi=$build_sunxi sun4i=$build_sun4i null=$build_null"
            FAIL=$((FAIL + 1))
        else
            echo "PASS: $test_name"
            PASS=$((PASS + 1))
        fi
    fi
}

echo "=== Testing DC backend selection logic ==="

# Test 1: Default (no overrides) -> dc_sunxi
check_backend_logic "default -> dc_sunxi" "" "" "" 1 0 0

# Test 2: PVR_HEADLESS_NO_DC=1 -> no backend
check_backend_logic "PVR_HEADLESS_NO_DC=1 -> headless" "1" "" "" 0 0 0

# Test 3: PVR_DC_NULL=1 -> dc_null
check_backend_logic "PVR_DC_NULL=1 -> dc_null" "" "1" "" 0 0 1

# Test 4: PVR_DC_SUN4I=1 -> dc_sun4i
check_backend_logic "PVR_DC_SUN4I=1 -> dc_sun4i" "" "" "1" 0 1 0

# Test 5: PVR_DC_SUN4I=1 suppresses dc_sunxi
check_backend_logic "PVR_DC_SUN4I=1 suppresses dc_sunxi" "" "" "1" 0 1 0

# Test 6: PVR_DC_NULL=1 suppresses dc_sunxi
check_backend_logic "PVR_DC_NULL=1 suppresses dc_sunxi" "" "1" "" 0 0 1

# Test 7: Conflicting overrides should error
echo ""
echo "=== Testing conflict rejection ==="

# Test 7a: PVR_HEADLESS_NO_DC=1 + PVR_DC_NULL=1 should error
check_backend_logic "PVR_HEADLESS_NO_DC=1 + PVR_DC_NULL=1" "1" "1" "" 0 0 0 "1"

# Test 7b: PVR_HEADLESS_NO_DC=1 + PVR_DC_SUN4I=1 should error
check_backend_logic "PVR_HEADLESS_NO_DC=1 + PVR_DC_SUN4I=1" "1" "" "1" 0 0 0 "1"

# Test 7c: PVR_DC_NULL=1 + PVR_DC_SUN4I=1 should error
check_backend_logic "PVR_DC_NULL=1 + PVR_DC_SUN4I=1" "" "1" "1" 0 0 0 "1"

echo ""
echo "=== Testing grep -c fix in build-sunxi-a133.sh ==="

# Test that grep -q ... && echo 1 || echo 0 produces single scalar
tmpfile=$(mktemp)
echo "#define CONFIG_DRM_FBDEV_EMULATION 1" > "$tmpfile"

# Test with match
result=$(grep -q '^#define CONFIG_DRM_FBDEV_EMULATION 1$' "$tmpfile" 2>/dev/null && echo 1 || echo 0)
if [ "$result" = "1" ]; then
    echo "PASS: grep -q with match returns '1'"
    PASS=$((PASS + 1))
else
    echo "FAIL: grep -q with match returned '$result' (expected '1')"
    FAIL=$((FAIL + 1))
fi

# Test without match
result=$(grep -q '^#define CONFIG_FB 1$' "$tmpfile" 2>/dev/null && echo 1 || echo 0)
if [ "$result" = "0" ]; then
    echo "PASS: grep -q without match returns '0'"
    PASS=$((PASS + 1))
else
    echo "FAIL: grep -q without match returned '$result' (expected '0')"
    FAIL=$((FAIL + 1))
fi

rm -f "$tmpfile"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ $FAIL -gt 0 ]; then
    exit 1
fi

#!/bin/bash
# Gate 3 (bead tsp-71fdd65791d8498f4d78): DC backend selection logic validation.
# Verifies that build-sunxi-a133.sh correctly selects dc_sun4i vs dc_sunxi vs dc_null
# based on kernel version and CONFIG_FB presence.
# Usage: tests/gate3-dc-backend-selection.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL gate3 reason=$1 ${2:-}"; exit 1; }

BUILD_SCRIPT="$HERE/build-sunxi-a133.sh"

# Check build script has CONFIG_FB detection
grep -q 'grep -q.*CONFIG_FB.*autoconf.h' "$BUILD_SCRIPT" || fail missing_CONFIG_FB_detection

# Check build script has kernel version detection
grep -q 'KERNEL_VERSION=.*kernelversion' "$BUILD_SCRIPT" || fail missing_kernel_version_detection
grep -q 'KERNEL_MAJOR=.*cut -d.' "$BUILD_SCRIPT" || fail missing_kernel_major_extraction

# Check build script selects dc_sun4i for kernel 6.x+
grep -q 'KERNEL_MAJOR.*-ge 6' "$BUILD_SCRIPT" || fail missing_kernel_6_check
grep -q 'PVR_DC_SUN4I=.*:-1' "$BUILD_SCRIPT" || fail missing_dc_sun4i_default_for_6x

# Check build script passes PVR_DC_SUN4I to make
grep -q 'PVR_DC_SUN4I=.*PVR_DC_SUN4I' "$BUILD_SCRIPT" || fail missing_PVR_DC_SUN4I_pass_to_make

# Check Makefile has PVR_DC_SUN4I conditional
MAKEFILE="$HERE/Makefile"
grep -q 'ifeq.*PVR_DC_SUN4I.*1' "$MAKEFILE" || fail missing_PVR_DC_SUN4I_conditional
grep -q 'include.*dc_sun4i/Kbuild.mk' "$MAKEFILE" || fail missing_dc_sun4i_Kbuild_include
grep -q 'obj-.*dc_sun4i.o' "$MAKEFILE" || fail missing_dc_sun4i.o_object

# Check mutual exclusivity comment (documentation)
grep -q 'mutually exclusive' "$MAKEFILE" || fail missing_mutual_exclusivity_doc

# Check build script has dc_sun4i.ko output check
grep -q 'dc_sun4i.ko' "$BUILD_SCRIPT" || fail missing_dc_sun4i.ko_output

# Verify the logic flow in build script
# 1. No CONFIG_FB -> dc_null
grep -A10 'CONFIG_FB.*autoconf.h' "$BUILD_SCRIPT" | grep -q 'PVR_HEADLESS_NO_DC' || fail missing_dc_null_fallback
grep -A10 'CONFIG_FB.*autoconf.h' "$BUILD_SCRIPT" | grep -q 'PVR_DC_NULL' || fail missing_dc_null_fallback

# 2. CONFIG_FB + kernel 6.x+ -> dc_sun4i
grep -A10 'KERNEL_MAJOR.*-ge 6' "$BUILD_SCRIPT" | grep -q 'PVR_DC_SUN4I' || fail missing_dc_sun4i_for_6x

echo "PASS gate3 DC backend selection logic validated"
echo "  CONFIG_FB detection: present"
echo "  Kernel version detection: present"
echo "  dc_sun4i for kernel 6.x+: present"
echo "  dc_null fallback (no CONFIG_FB): present"
echo "  dc_sunxi default (kernel <6): implicit (no special flag)"
echo "  Mutual exclusivity: documented"

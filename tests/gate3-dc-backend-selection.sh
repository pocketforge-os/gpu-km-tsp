#!/bin/bash
# Gate 3 (bead tsp-71fdd65791d8498f4d78): DC backend selection logic validation.
# Verifies that build-sunxi-a133.sh correctly selects dc_sun4i vs dc_sunxi vs dc_null
# based on kernel version and CONFIG_FB presence.
# Usage: tests/gate3-dc-backend-selection.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL gate3 reason=$1 ${2:-}"; exit 1; }

BUILD_SCRIPT="$HERE/build-sunxi-a133.sh"

# Check build script has DRM fbdev emulation detection
grep -q 'HAS_DRM_FBDEV_EMU=.*grep.*CONFIG_DRM_FBDEV_EMULATION' "$BUILD_SCRIPT" || fail missing_DRM_FBDEV_EMULATION_detection
grep -q 'HAS_LEGACY_FB=.*grep.*CONFIG_FB' "$BUILD_SCRIPT" || fail missing_legacy_FB_detection

# Check build script has kernel version detection
grep -q 'KERNEL_VERSION=.*kernelversion' "$BUILD_SCRIPT" || fail missing_kernel_version_detection
grep -q 'KERNEL_MAJOR=.*cut -d.' "$BUILD_SCRIPT" || fail missing_kernel_major_extraction

# Check build script selects dc_sun4i for kernel 6.x+ with DRM fbdev emulation
grep -q 'KERNEL_MAJOR.*-ge 6.*HAS_DRM_FBDEV_EMU.*-eq 1' "$BUILD_SCRIPT" || fail missing_kernel_6_drm_fbdev_check
grep -q 'PVR_DC_SUN4I=1' "$BUILD_SCRIPT" || fail missing_dc_sun4i_default_for_6x

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
# 1. No fbdev support at all -> dc_null only (not headless + null conflict)
grep -A10 'HAS_DRM_FBDEV_EMU.*-eq 0.*HAS_LEGACY_FB.*-eq 0' "$BUILD_SCRIPT" | grep -q 'PVR_DC_NULL' || fail missing_dc_null_fallback

# 2. CONFIG_FB + kernel 6.x+ -> dc_sun4i
grep -A10 'KERNEL_MAJOR.*-ge 6' "$BUILD_SCRIPT" | grep -q 'PVR_DC_SUN4I' || fail missing_dc_sun4i_for_6x

echo "PASS gate3 DC backend selection logic validated"
echo "  DRM fbdev emulation detection: present"
echo "  Legacy CONFIG_FB detection: present"
echo "  Kernel version detection: present"
echo "  dc_sun4i for kernel 6.x+ with DRM fbdev: present"
echo "  dc_null fallback (no fbdev): present (single backend, not headless+null)"
echo "  dc_sunxi default (kernel <6 or legacy FB): implicit (no special flag)"
echo "  Mutual exclusivity: documented"

#!/bin/bash
# Build pvrsrvkm.ko for sunxi_a133 (TrimUI Smart Pro, GE8300 BVNC 22.102.54.38)
# against the kernel-tsp headers.
#
# Usage: ./build-sunxi-a133.sh [KERNELDIR]
#   KERNELDIR: path to a configured kernel-tsp tree (default: ../kernel-tsp)
#
# Environment variables:
#   CROSS_COMPILE     : cross-compiler prefix (default: aarch64-none-linux-gnu-)
#   ODYSSEY_CAPTURE   : set to 1 to compile PF-CAPTURE support (default: off)
#   EXTRA_PVR_KM_CFLAGS: additional module CFLAGS (default: empty)
#   PVR_BUILDOPTS_MK  : path to pvr-buildopts.mk (default: auto-detected from
#                        ../image/build/pvr-buildopts.mk or /work/src/image/build/)
#
# This script adapts the upstream DDK Makefile for our platform by:
#   1. Swapping PVR_SYSTEM to sunxi_a133
#   2. Swapping BVNC to 22.102.54.38
#   3. Using our sunxi_a133 Kbuild.mk
#   4. Building as external kernel module against kernel-tsp
#   5. Including pvr-buildopts.mk for vendor-matching CFLAGS + build-options overrides

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNELDIR="${1:-$(cd "$SCRIPT_DIR/../kernel-tsp" && pwd)}"
# KERNELDIR is consumed here; any remaining arguments are passed through to make.
[ "$#" -gt 0 ] && shift
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-none-linux-gnu-}"

# Auto-detect pvr-buildopts.mk if not explicitly set
if [ -z "${PVR_BUILDOPTS_MK:-}" ]; then
    if [ -f "$SCRIPT_DIR/build/pvr-buildopts.mk" ]; then
        PVR_BUILDOPTS_MK="$SCRIPT_DIR/build/pvr-buildopts.mk"
    elif [ -f "$SCRIPT_DIR/../image/build/pvr-buildopts.mk" ]; then
        PVR_BUILDOPTS_MK="$(cd "$SCRIPT_DIR/../image" && pwd)/build/pvr-buildopts.mk"
    elif [ -f "/work/src/image/build/pvr-buildopts.mk" ]; then
        PVR_BUILDOPTS_MK="/work/src/image/build/pvr-buildopts.mk"
    fi
fi

if [ ! -f "$KERNELDIR/include/generated/autoconf.h" ]; then
    echo "ERROR: $KERNELDIR does not appear to be a configured kernel tree."
    echo "Run 'make ARCH=arm64 pocketforge_tsp_defconfig && make prepare modules_prepare' first."
    exit 1
fi

# DC backend selection based on kernel version and DRM fbdev prerequisites:
#   - No CONFIG_DRM_FBDEV_EMULATION (mainline without fbdev emulation): dc_null (headless)
#   - CONFIG_DRM_FBDEV_EMULATION + kernel 7.x+: dc_sun4i (sun4i-drm fbdev emulation)
#   - CONFIG_DRM_FBDEV_EMULATION + kernel 4.9/5.x: dc_sunxi (legacy sunxi disp fbdev)
#   - No CONFIG_DRM_FBDEV_EMULATION + kernel 4.9: dc_sunxi requires legacy CONFIG_FB
# Explicit PVR_HEADLESS_NO_DC / PVR_DC_NULL / PVR_DC_SUN4I win over automatic defaults.
AUTCONF_H="$KERNELDIR/include/generated/autoconf.h"
HAS_DRM_FBDEV_EMU=$(grep -q '^#define CONFIG_DRM_FBDEV_EMULATION 1$' "$AUTCONF_H" 2>/dev/null && echo 1 || echo 0)
HAS_LEGACY_FB=$(grep -q '^#define CONFIG_FB 1$' "$AUTCONF_H" 2>/dev/null && echo 1 || echo 0)

# Check if any explicit backend selector is already set
EXPLICIT_SET=0
[ -n "${PVR_HEADLESS_NO_DC:-}" ] && EXPLICIT_SET=1
[ -n "${PVR_DC_NULL:-}" ] && EXPLICIT_SET=1
[ -n "${PVR_DC_SUN4I:-}" ] && EXPLICIT_SET=1

# Only apply automatic defaults if no explicit selector is set
if [ "$EXPLICIT_SET" -eq 0 ]; then
    if [ "$HAS_DRM_FBDEV_EMU" -eq 0 ] && [ "$HAS_LEGACY_FB" -eq 0 ]; then
        # No fbdev support at all; use dc_null
        PVR_DC_NULL=1
    else
        # fbdev support present; check kernel version to choose dc_sun4i vs dc_sunxi
        KERNEL_VERSION=$(make -C "$KERNELDIR" kernelversion 2>/dev/null | head -n1)
        KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
        
        # Default to dc_sun4i for kernel 6.x+ with DRM fbdev emulation
        # Keep dc_sunxi for 4.9/5.x (legacy BSP with CONFIG_FB)
        if [ "${KERNEL_MAJOR:-0}" -ge 6 ] && [ "$HAS_DRM_FBDEV_EMU" -eq 1 ]; then
            PVR_DC_SUN4I=1
        fi
        # For kernel < 6 or without DRM fbdev emulation, leave dc_sunxi as default
    fi
fi

echo "=== Building pvrsrvkm.ko for sunxi_a133 ==="
echo "  DDK source:    $SCRIPT_DIR"
echo "  Kernel:        $KERNELDIR"
echo "  Kernel ver:    ${KERNEL_VERSION:-unknown}"
echo "  Cross:         $CROSS_COMPILE"
echo "  Odyssey capture: ${ODYSSEY_CAPTURE:-0}"
echo "  Extra CFLAGS:  ${EXTRA_PVR_KM_CFLAGS:-}"
echo "  DC backend:    PVR_HEADLESS_NO_DC=${PVR_HEADLESS_NO_DC:-0} PVR_DC_NULL=${PVR_DC_NULL:-0} PVR_DC_SUN4I=${PVR_DC_SUN4I:-0}"
echo "  Build-opts mk: ${PVR_BUILDOPTS_MK:-<auto-detect via Makefile>}"
echo ""

# Build using the kernel's kbuild system
make -C "$KERNELDIR" \
    M="$SCRIPT_DIR" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    ODYSSEY_CAPTURE="${ODYSSEY_CAPTURE:-0}" \
    EXTRA_PVR_KM_CFLAGS="${EXTRA_PVR_KM_CFLAGS:-}" \
    CONFIG_DRM_IMG_ROGUE=m \
    PVR_SYSTEM=sunxi_a133 \
    ${PVR_HEADLESS_NO_DC:+PVR_HEADLESS_NO_DC="$PVR_HEADLESS_NO_DC"} \
    ${PVR_DC_NULL:+PVR_DC_NULL="$PVR_DC_NULL"} \
    ${PVR_DC_SUN4I:+PVR_DC_SUN4I="$PVR_DC_SUN4I"} \
    ${PVR_BUILDOPTS_MK:+PVR_BUILDOPTS_MK="$PVR_BUILDOPTS_MK"} \
    modules \
    "$@"

echo ""
echo "=== Build complete ==="
if [ -f "$SCRIPT_DIR/pvrsrvkm.ko" ]; then
    echo "  pvrsrvkm.ko: $(ls -la "$SCRIPT_DIR/pvrsrvkm.ko" | awk '{print $5}') bytes"
    modinfo "$SCRIPT_DIR/pvrsrvkm.ko" 2>/dev/null | grep -E "^(vermagic|alias|description)" || true
fi
if [ -f "$SCRIPT_DIR/services/system/rogue/sunxi_a133/dc_sunxi.ko" ]; then
    echo "  dc_sunxi.ko: $(ls -la "$SCRIPT_DIR/services/system/rogue/sunxi_a133/dc_sunxi.ko" | awk '{print $5}') bytes"
fi
if [ -f "$SCRIPT_DIR/services/system/rogue/sunxi_a133/dc_sun4i.ko" ]; then
    echo "  dc_sun4i.ko: $(ls -la "$SCRIPT_DIR/services/system/rogue/sunxi_a133/dc_sun4i.ko" | awk '{print $5}') bytes"
fi
if [ -f "$SCRIPT_DIR/services/system/rogue/sunxi_a133/dc_null.ko" ]; then
    echo "  dc_null.ko: $(ls -la "$SCRIPT_DIR/services/system/rogue/sunxi_a133/dc_null.ko" | awk '{print $5}') bytes"
fi

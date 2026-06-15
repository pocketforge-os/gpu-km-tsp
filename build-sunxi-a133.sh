#!/bin/bash
# Build pvrsrvkm.ko for sunxi_a133 (TrimUI Smart Pro, GE8300 BVNC 22.102.54.38)
# against the kernel-tsp headers.
#
# Usage: ./build-sunxi-a133.sh [KERNELDIR]
#   KERNELDIR: path to a configured kernel-tsp tree (default: ../kernel-tsp)
#
# Environment variables:
#   CROSS_COMPILE     : cross-compiler prefix (default: aarch64-none-linux-gnu-)
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

echo "=== Building pvrsrvkm.ko for sunxi_a133 ==="
echo "  DDK source:    $SCRIPT_DIR"
echo "  Kernel:        $KERNELDIR"
echo "  Cross:         $CROSS_COMPILE"
echo "  Build-opts mk: ${PVR_BUILDOPTS_MK:-<auto-detect via Makefile>}"
echo ""

# Build using the kernel's kbuild system
make -C "$KERNELDIR" \
    M="$SCRIPT_DIR" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CONFIG_DRM_IMG_ROGUE=m \
    PVR_SYSTEM=sunxi_a133 \
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

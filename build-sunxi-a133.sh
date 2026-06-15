#!/bin/bash
# Build pvrsrvkm.ko for sunxi_a133 (TrimUI Smart Pro, GE8300 BVNC 22.102.54.38)
# against the kernel-tsp headers.
#
# Usage: ./build-sunxi-a133.sh [KERNELDIR]
#   KERNELDIR: path to a configured kernel-tsp tree (default: ../kernel-tsp)
#
# This script adapts the upstream DDK Makefile for our platform by:
#   1. Swapping PVR_SYSTEM to sunxi_a133
#   2. Swapping BVNC to 22.102.54.38
#   3. Using our sunxi_a133 Kbuild.mk
#   4. Building as external kernel module against kernel-tsp

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNELDIR="${1:-$(cd "$SCRIPT_DIR/../kernel-tsp" && pwd)}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-none-linux-gnu-}"

if [ ! -f "$KERNELDIR/include/generated/autoconf.h" ]; then
    echo "ERROR: $KERNELDIR does not appear to be a configured kernel tree."
    echo "Run 'make ARCH=arm64 pocketforge_tsp_defconfig && make prepare modules_prepare' first."
    exit 1
fi

echo "=== Building pvrsrvkm.ko for sunxi_a133 ==="
echo "  DDK source: $SCRIPT_DIR"
echo "  Kernel:     $KERNELDIR"
echo "  Cross:      $CROSS_COMPILE"
echo ""

# Build using the kernel's kbuild system
make -C "$KERNELDIR" \
    M="$SCRIPT_DIR" \
    ARCH=arm64 \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CONFIG_DRM_IMG_ROGUE=m \
    modules \
    "$@"

echo ""
echo "=== Build complete ==="
if [ -f "$SCRIPT_DIR/pvrsrvkm.ko" ]; then
    echo "  pvrsrvkm.ko: $(ls -la "$SCRIPT_DIR/pvrsrvkm.ko" | awk '{print $5}') bytes"
    modinfo "$SCRIPT_DIR/pvrsrvkm.ko" 2>/dev/null | grep -E "^(vermagic|alias|description)" || true
fi

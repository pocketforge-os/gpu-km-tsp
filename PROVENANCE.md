# Provenance

This repository contains the PowerVR Rogue DDK 1.19 kernel module (KM)
source, extracted from a publicly available Linux kernel fork. PocketForge
maintains this fork to build `pvrsrvkm.ko` and `dc_sunxi.ko` from source
against the PocketForge-owned kernel (`pocketforge-os/kernel-tsp`).

## Upstream source

| Field            | Value |
|------------------|-------|
| Repository       | [DC-DeepComputing/fml13v01-linux](https://github.com/DC-DeepComputing/fml13v01-linux) |
| Branch           | `fm7110-6.6` (default branch) |
| Commit SHA       | `97c64fe2832b6826914b6da7aa4febcdd4d3d444` |
| Commit date      | 2025-05-13 |
| Commit message   | `riscv: configs: fml13v01_defconfig: undefined CONFIG_LOCALVERSION_AUTO` |
| Extraction path  | `drivers/gpu/drm/img/img-rogue/` |
| Extraction date  | 2026-06-14 |

## DDK version

| Field               | Value |
|----------------------|-------|
| DDK branch           | `1.19` |
| DDK build            | `6345021` |
| DDK version string   | `Rogue_DDK_Linux_WS rogueddk 1.19@6345021` |
| Source file          | `include/pvrversion.h` |

## Target silicon

| Field   | Value |
|---------|-------|
| GPU     | Imagination GE8300 (PowerVR Rogue) |
| BVNC    | 22.102.54.38 |
| SoC     | Allwinner A133 (sun50iw10) |
| Device  | TrimUI Smart Pro |
| Header  | `hwdefs/rogue/km/cores/rgxcore_km_22.102.54.38.h` |

## What was extracted

The entire `drivers/gpu/drm/img/img-rogue/` subtree from the upstream
repository, containing:

- `generated/` -- auto-generated bridge code
- `hwdefs/` -- hardware definitions for all supported Rogue cores
- `include/` -- public and private DDK headers
- `services/` -- kernel services (server, common, system layers)
- `Kconfig`, `Makefile`, `config_kernel.h`, `config_kernel.mk`

The checked-in `config_kernel.h` and `config_kernel.mk` target the
StarFive FM7110 (RISC-V, BVNC 36.50.54.182). PocketForge replaces these
with A133-specific configuration (BVNC 22.102.54.38, ARM64).

## What was NOT extracted

Everything outside `drivers/gpu/drm/img/img-rogue/` in the upstream
repository: the Linux kernel tree, device trees, other drivers, build
infrastructure, etc.

## Upstream license

All Imagination Technologies source files carry `@License Dual MIT/GPLv2`
headers referencing `MIT-COPYING` and `GPL-COPYING`. A small number of
public API headers (`include/public/powervr/`) are MIT-only. Platform
system-layer files contributed by third parties (e.g. MediaTek `mt8173`)
carry their own GPL-2.0 headers.

See `LICENSE`, `MIT-COPYING`, and `GPL-COPYING` in this repository.

## PocketForge modifications

PocketForge's fork adds:

1. **`services/system/rogue/sunxi_a133/`** -- A133/sun50iw10 system layer,
   ported from the DDK 1.11 sunxi system layer in
   `CrealityTech/sonic_pad_os` (GPL-2.0).
2. **Build configuration** -- replacement `config_kernel.h` and
   `config_kernel.mk` targeting BVNC 22.102.54.38, ARM64, nullws.
3. **Build-options strict-mask** -- `RGX_BUILD_OPTIONS_KM` constant
   override matching the vendor `pvrsrvkm.ko` bitmask (`0x0060d13d`).

All PocketForge-authored files are dual MIT/GPLv2, matching the upstream
convention.

## Upstream tracking

The `upstream` branch tracks the upstream repository for visibility.
Periodic fetches (monthly target) from
`DC-DeepComputing/fml13v01-linux:fm7110-6.6` are merged into `upstream`.
Cherry-picks to `main` are made only when absorbing a specific upstream
change.

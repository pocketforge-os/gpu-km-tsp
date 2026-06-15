# Contributing to gpu-km-tsp

## Branch strategy

| Branch | Purpose |
|--------|---------|
| `main` | Current development HEAD. All changes land via PR. |
| `upstream` | Passive tracking of `DC-DeepComputing/fml13v01-linux:fm7110-6.6`. Fetch-only; never commit directly. |
| `release/<tag>` | Signed release tags. Format: `tsp-ddk1.19-<YYYY.MM.DD>-<short-sha>`. |

## Pull request requirements

- PRs to `main` require CI to pass (build verification).
- PRs require at least 1 reviewer.
- All commits must be signed (`git commit -S`).
- Force-push is prohibited on `main` and `release/*` branches.

## Commit messages

Use clear, imperative-mood commit messages. Prefix with a scope when
applicable:

```
sunxi_a133: port SysDevInit to DDK 1.19 API
build: add aarch64-none-linux-gnu compiler config
hwdefs: no changes (upstream import)
```

## Build verification

Before submitting a PR, verify the module builds:

```sh
# Inside the pocketforge/build container, with kernel-tsp at /work/kernel:
make -C /work/kernel \
  M=/work/gpu \
  ARCH=arm64 \
  CROSS_COMPILE=aarch64-none-linux-gnu- \
  PVR_SYSTEM=sunxi_a133 \
  CONFIG_DRM_IMG_ROGUE=m \
  modules
```

The kernel must have been built with `modules_prepare` first (for
`Module.symvers` and generated headers). The output `pvrsrvkm.ko`
appears in the gpu-km-tsp root.

Verify the built module:

```sh
aarch64-none-linux-gnu-readelf -p .modinfo pvrsrvkm.ko
```

Expected fields:
- `vermagic=4.9.191 SMP preempt mod_unload aarch64`
- `alias=platform:rgxsunxi`
- `alias=of:N*T*Cimg,gpu`

## sunxi_a133 system layer port

The `services/system/rogue/sunxi_a133/` directory is the Allwinner A133
(TrimUI Smart Pro) system layer, ported from the vendor DDK 1.11
(`sonic_pad_os`) to the DDK 1.19 API surface.

### Port scope

| File | Origin | Changes from DDK 1.11 |
|------|--------|-----------------------|
| `sysconfig.c` | Rewritten | Static device config (no OSAllocZMem); `ui32UsageFlags` phys-heap; `eDefaultHeap`; BIF tiling removed; new 1.19 fields added |
| `sysconfig.h` | Trimmed | BIF tiling globals removed; only `SYS_RGX_ACTIVE_POWER_LATENCY_MS` retained |
| `sysinfo.h` | Verbatim | `rgxsunxi` / `img,gpu` aliases match closed binary modinfo |
| `platform.h` | Signature update | Power callbacks: `PVRSRV_SYS_POWER_STATE` + `PVRSRV_POWER_FLAGS` |
| `sunxi_platform.c` | Signature update | Two functions updated for 1.19 power-state enums; 700+ lines of clock/DVFS/debugfs/sysfs unchanged |
| `Kbuild.mk` | New (sf_7110 pattern) | Object list for sunxi_a133 platform files + VZ common |

### Key 1.11 to 1.19 API changes handled

- `PHYS_HEAP_CONFIG`: `ui32PhysHeapID` removed; uses `ui32UsageFlags`
  bitmask + `eDefaultHeap` on `PVRSRV_DEVICE_CONFIG`
- BIF tiling removed: `eBIFTilingMode`, `pui32BIFTilingHeapConfigs`,
  `ui32BIFTilingHeapCount` all deleted
- New fields: `bHasFBCDCVersion31`, `bDevicePA0IsValid`,
  `pfnSysDevErrorNotify`, `pfnHostCacheMaintenance`
- Power callbacks: `PVRSRV_DEV_POWER_STATE` + `IMG_BOOL bForced`
  became `PVRSRV_SYS_POWER_STATE` + `PVRSRV_POWER_FLAGS ePwrFlags`
- Include: `vz_support.h` renamed to `vz_vmm_pvz.h`

### M2.A spike resolutions applied

- **pfnHostCacheMaintenance = NULL** is safe: zero call sites in DDK
  common code; ARM64 Cortex-A53 cache ops go through
  `OSCPUCache*RangeKM` (spike `tsp-cv7.1.1`)
- **SUPPORT_PDVFS omitted**: runtime no-op when not defined; vendor
  build-options bit 9 = 0; `sunxi_platform.c` manages DVFS directly
  via clk/regulator APIs (spike `tsp-cv7.1.2`)

### Kernel-version compatibility headers

The DDK 1.19 code targets newer kernels (5.x/6.x) but we build against
4.9.191. Several compat headers bridge the gap:

| Header | Purpose |
|--------|---------|
| `kernel_compatibility.h` | Kernel API compat (from vendor DDK 1.11 staging + upstream DDK shims for `dma_buf_vmap`/`iosys_map`/`mmap_write_lock`/`vm_flags_set`/`register_shrinker`/`MODULE_IMPORT_NS`) |
| `kernel_nospec.h` | `array_index_nospec` compat for kernels < 4.15 |
| `pvr_linux_fence.h` | `dma_fence` vs `fence` compat for kernels < 4.10 |
| `pvr_dma_resv.h` | `dma_resv` vs `reservation_object` compat for kernels < 5.4 (from upstream DDK) |
| `pvr_vmap.h` | `pvr_vmap`/`pvr_vunmap` wrappers around kernel `vmap`/`vunmap` |

### Platform-conditional code in shared files

- `module_common.c`: `sPVRSRVDeviceSuspend`/`sPVRSRVDeviceResume`
  guarded by `#if defined(PVR_SYSTEM_SF7110)` (sf7110 calls
  `sys_get_privdata()`; sunxi_a133 uses no-op stubs -- platform
  suspend/resume is handled by `sunxi_platform.c` power callbacks)
- `config_kernel.h`: `PVR_SYSTEM_SF7110` defined for sf7110 builds only

## License convention

All new files must carry the dual MIT/GPLv2 license header matching the
upstream Imagination convention:

```c
/*************************************************************************/ /*!
@File           <filename>
@Title          <brief description>
@Copyright      Copyright (c) Imagination Technologies Ltd. All Rights Reserved
@Description    <description>
@License        Dual MIT/GPLv2

The contents of this file are subject to the MIT license as set out below.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

Alternatively, the contents of this file may be used under the terms of
the GNU General Public License Version 2 ("GPL") in which case the
provisions of GPL are applicable instead of those above.

If you wish to allow use of your version of this file only under the terms
of GPL, and not to allow others to use your version of this file under the
terms of the MIT license, indicate your decision by deleting the provisions
above and replace them with the notice and other provisions required by GPL
as set out in the file called "GPL-COPYING" included in this distribution.
If you do not delete the provisions above, a recipient may use your version
of this file under the terms of either the MIT license or GPL.

This License is also included in this distribution in the file called
"MIT-COPYING".

EXCEPT AS OTHERWISE STATED IN A NEGOTIATED AGREEMENT: (A) THE SOFTWARE IS
PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR
A PARTICULAR PURPOSE AND NONINFRINGEMENT; AND (B) IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/ /**************************************************************************/
```

For PocketForge-authored files, replace the `@Copyright` line with:

```
@Copyright      Copyright (c) PocketForge contributors. All Rights Reserved.
```

## Reporting issues

File issues in [pocketforge-os/gpu-km-tsp](https://github.com/pocketforge-os/gpu-km-tsp/issues)
or in the parent project tracker.

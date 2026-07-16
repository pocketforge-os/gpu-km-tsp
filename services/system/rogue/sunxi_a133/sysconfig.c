/*************************************************************************/ /*!
@File
@Title          System Configuration
@Copyright      Copyright (c) Imagination Technologies Ltd. All Rights Reserved
@Description    System Configuration functions
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
the GNU General Public License Version 2 ("GPL") in which case the provisions
of GPL are applicable instead of those above.

If you wish to allow use of your version of this file only under the terms of
GPL, and not to allow others to use your version of this file under the terms
of the MIT license, indicate your decision by deleting the provisions above
and replace them with the notice and other provisions required by GPL as set
out in the file called "GPL-COPYING" included in this distribution. If you do
not delete the provisions above, a recipient may use your version of this file
under the terms of either the MIT license or GPL.

This License is also included in this distribution in the file called
"MIT-COPYING".

EXCEPT AS OTHERWISE STATED IN A NEGOTIATED AGREEMENT: (A) THE SOFTWARE IS
PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE AND NONINFRINGEMENT; AND (B) IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/ /**************************************************************************/

/*
 * PocketForge sunxi_a133 system layer for DDK 1.19.
 *
 * Ported from sonic_pad_os DDK 1.11 services/system/sunxi/ to the DDK 1.19
 * API.  The sunxi_platform.c platform code (clock, power, DVFS management)
 * is carried forward with only power-callback signature changes.
 *
 * Key 1.11 -> 1.19 changes in this file:
 *   - Static device config / phys-heap / timing structs (no OSAllocZMem)
 *   - PHYS_HEAP_CONFIG uses ui32UsageFlags instead of ui32PhysHeapID
 *   - eDefaultHeap replaces aui32PhysHeapID[] array
 *   - BIF tiling block removed (eBIFTilingMode, pui32BIFTilingHeapConfigs)
 *   - New fields: bHasFBCDCVersion31, bDevicePA0IsValid,
 *     pfnSysDevErrorNotify, pfnHostCacheMaintenance
 *   - pfnHostCacheMaintenance = NULL (safe per M2.A spike tsp-cv7.1.1:
 *     zero callers in DDK common code; ARM64 cache ops go through
 *     OSCPUCache*RangeKM)
 *   - vz_support.h -> vz_vmm_pvz.h
 *   - Power callbacks: PVRSRV_SYS_POWER_STATE + PVRSRV_POWER_FLAGS
 *     (not PVRSRV_DEV_POWER_STATE + IMG_BOOL)
 *   - SUPPORT_PDVFS omitted (optional per M2.A spike tsp-cv7.1.2:
 *     vendor build-options bit 9 = 0; sunxi_platform.c manages DVFS
 *     directly via clk/regulator APIs)
 */

#include "pvrsrv_device.h"
#include "syscommon.h"
#include "allocmem.h"
#include "sysinfo.h"
#include "sysconfig.h"
#include "physheap.h"
#include "vz_vmm_pvz.h"
#include "interrupt_support.h"

#if defined(__linux__)
#include <linux/clk.h>
#include <linux/dma-mapping.h>
#include <linux/platform_device.h>
#endif

#include "platform.h"

/* Static device configuration (DDK 1.19 pattern) */
static RGX_TIMING_INFORMATION	gsRGXTimingInfo;
static RGX_DATA			gsRGXData;
static PVRSRV_DEVICE_CONFIG	gsDevices[1];
static PHYS_HEAP_FUNCTIONS	gsPhysHeapFuncs;
static PHYS_HEAP_CONFIG		gsPhysHeapConfig[1];

/*
	CPU to Device physical address translation
*/
static
void UMAPhysHeapCpuPAddrToDevPAddr(IMG_HANDLE hPrivData,
								   IMG_UINT32 ui32NumOfAddr,
								   IMG_DEV_PHYADDR *psDevPAddr,
								   IMG_CPU_PHYADDR *psCpuPAddr)
{
	PVR_UNREFERENCED_PARAMETER(hPrivData);

	/* Optimise common case */
	psDevPAddr[0].uiAddr = psCpuPAddr[0].uiAddr;
	if (ui32NumOfAddr > 1)
	{
		IMG_UINT32 ui32Idx;
		for (ui32Idx = 1; ui32Idx < ui32NumOfAddr; ++ui32Idx)
		{
			psDevPAddr[ui32Idx].uiAddr = psCpuPAddr[ui32Idx].uiAddr;
		}
	}
}

/*
	Device to CPU physical address translation
*/
static
void UMAPhysHeapDevPAddrToCpuPAddr(IMG_HANDLE hPrivData,
								   IMG_UINT32 ui32NumOfAddr,
								   IMG_CPU_PHYADDR *psCpuPAddr,
								   IMG_DEV_PHYADDR *psDevPAddr)
{
	PVR_UNREFERENCED_PARAMETER(hPrivData);

	/* Optimise common case */
	psCpuPAddr[0].uiAddr = psDevPAddr[0].uiAddr;
	if (ui32NumOfAddr > 1)
	{
		IMG_UINT32 ui32Idx;
		for (ui32Idx = 1; ui32Idx < ui32NumOfAddr; ++ui32Idx)
		{
			psCpuPAddr[ui32Idx].uiAddr = psDevPAddr[ui32Idx].uiAddr;
		}
	}
}

static void SysDevFeatureDepInit(PVRSRV_DEVICE_CONFIG *psDevConfig, IMG_UINT64 ui64Features)
{
#if defined(SUPPORT_AXI_ACE_TEST)
	if (ui64Features & RGX_FEATURE_AXI_ACELITE_BIT_MASK)
	{
		psDevConfig->eCacheSnoopingMode = PVRSRV_DEVICE_SNOOP_CPU_ONLY;
	}
	else
#endif
	{
		psDevConfig->eCacheSnoopingMode = PVRSRV_DEVICE_SNOOP_NONE;
	}
}

PVRSRV_ERROR SysDevInit(void *pvOSDevice, PVRSRV_DEVICE_CONFIG **ppsDevConfig)
{
	struct device *dev = (struct device *)pvOSDevice;
	struct sunxi_platform *sunxi_data;

	if (gsDevices[0].pvOSDevice)
		return PVRSRV_ERROR_INVALID_DEVICE;

	if (sunxi_platform_init(dev))
		return PVRSRV_ERROR_INIT_FAILURE;

	sunxi_data = (struct sunxi_platform *)dev->platform_data;

#if defined(__linux__)
	/* dma_coerce_mask_and_coherent(), not a bare dma_set_mask(): it wires
	 * dev->dma_mask = &dev->coherent_dma_mask BEFORE writing the value, so
	 * a platform device whose dma_mask pointer was never populated by the
	 * bus/of layer cannot be left with an invalid pointer there. A bare
	 * dma_set_mask() on such a device fails, the old code IGNORED that
	 * failure, and the first *dev->dma_mask deref oopsed
	 * (OSPhyContigPagesAlloc, VA 0xffffffff — tsp-mc9m.9, mainline A133).
	 */
	if (dma_coerce_mask_and_coherent(pvOSDevice, DMA_BIT_MASK(32)))
	{
		dev_err(dev, "pvrsrvkm: failed to set 32-bit DMA mask\n");
		return PVRSRV_ERROR_INIT_FAILURE;
	}
#endif

	/*
	 * Setup information about physical memory heap(s) we have.
	 * DDK 1.19: single UMA heap with ui32UsageFlags, not PhysHeapsCreate().
	 */
	gsPhysHeapFuncs.pfnCpuPAddrToDevPAddr = UMAPhysHeapCpuPAddrToDevPAddr;
	gsPhysHeapFuncs.pfnDevPAddrToCpuPAddr = UMAPhysHeapDevPAddrToCpuPAddr;

	gsPhysHeapConfig[0].pszPDumpMemspaceName = "SYSMEM";
	gsPhysHeapConfig[0].eType = PHYS_HEAP_TYPE_UMA;
	gsPhysHeapConfig[0].psMemFuncs = &gsPhysHeapFuncs;
	gsPhysHeapConfig[0].hPrivData = NULL;
	gsPhysHeapConfig[0].ui32UsageFlags = PHYS_HEAP_USAGE_GPU_LOCAL;

	/*
	 * Setup RGX specific timing data
	 */
	gsRGXTimingInfo.ui32CoreClockSpeed = clk_get_rate(sunxi_data->clks.core);
	if (sunxi_ic_version_ctrl(dev)) {
		gsRGXTimingInfo.bEnableActivePM = IMG_TRUE;
	} else {
		gsRGXTimingInfo.bEnableActivePM = IMG_FALSE;
	}
	gsRGXTimingInfo.bEnableRDPowIsland = IMG_TRUE;
	gsRGXTimingInfo.ui32ActivePMLatencyms = SYS_RGX_ACTIVE_POWER_LATENCY_MS;

	/* Setup RGX data */
	gsRGXData.psRGXTimingInfo = &gsRGXTimingInfo;

	/* Setup device config */
	gsDevices[0].pvOSDevice = pvOSDevice;
	gsDevices[0].pszName = "sunxi";
	gsDevices[0].pszVersion = NULL;
	gsDevices[0].pfnSysDevFeatureDepInit = &SysDevFeatureDepInit;

	/* Device setup information */
	gsDevices[0].sRegsCpuPBase.uiAddr = sunxi_data->reg_base;
	gsDevices[0].ui32RegsSize = sunxi_data->reg_size;
	gsDevices[0].ui32IRQ = sunxi_data->irq_num;

	/* DDK 1.19: eDefaultHeap replaces aui32PhysHeapID[] */
	gsDevices[0].eDefaultHeap = PVRSRV_PHYS_HEAP_GPU_LOCAL;

	/* Physical heaps */
	gsDevices[0].pasPhysHeaps = gsPhysHeapConfig;
	gsDevices[0].ui32PhysHeapCount = ARRAY_SIZE(gsPhysHeapConfig);

	/*
	 * DDK 1.19 fields (not present in 1.11):
	 * - BIF tiling removed (no eBIFTilingMode / pui32BIFTilingHeapConfigs)
	 * - bHasFBCDCVersion31: GE8300 does not have FBCDC v3.1
	 * - bDevicePA0IsValid: device PA 0 is not a valid GPU address
	 * - pfnSysDevErrorNotify: no system-layer error handler
	 * - pfnHostCacheMaintenance: NULL is safe for ARM64 Cortex-A53
	 *   (standard cache hierarchy; cache ops go through OSCPUCache*RangeKM)
	 */
	gsDevices[0].bHasFBCDCVersion31 = IMG_FALSE;
	gsDevices[0].bDevicePA0IsValid = IMG_FALSE;
	gsDevices[0].pfnSysDevErrorNotify = NULL;
	gsDevices[0].pfnHostCacheMaintenance = NULL;

	/* Power management */
	gsDevices[0].pfnPrePowerState = sunxiPrePowerState;
	gsDevices[0].pfnPostPowerState = sunxiPostPowerState;

	/* No clock frequency callback */
	gsDevices[0].pfnClockFreqGet = NULL;

	gsDevices[0].hDevData = &gsRGXData;
	gsDevices[0].hSysData = sunxi_data;

	/*
	 * PDVFS intentionally omitted (M2.A spike tsp-cv7.1.2: SUPPORT_PDVFS
	 * is optional; runtime no-op when not defined; vendor build-options
	 * bit 9 = 0).  GPU frequency/voltage managed externally by
	 * sunxi_platform.c via clk_set_rate() / regulator framework, matching
	 * the sonic_pad_os DDK 1.11 pattern.
	 */

	sunxi_data->config = &gsDevices[0];
	*ppsDevConfig = &gsDevices[0];

	return PVRSRV_OK;
}

void SysDevDeInit(PVRSRV_DEVICE_CONFIG *psDevConfig)
{
	sunxi_platform_term();
	psDevConfig->pvOSDevice = NULL;
}

PVRSRV_ERROR SysInstallDeviceLISR(IMG_HANDLE hSysData,
								  IMG_UINT32 ui32IRQ,
								  const IMG_CHAR *pszName,
								  PFN_LISR pfnLISR,
								  void *pvData,
								  IMG_HANDLE *phLISRData)
{
	PVR_UNREFERENCED_PARAMETER(hSysData);
	return OSInstallSystemLISR(phLISRData, ui32IRQ, pszName, pfnLISR, pvData,
								SYS_IRQ_FLAG_TRIGGER_DEFAULT);
}

PVRSRV_ERROR SysUninstallDeviceLISR(IMG_HANDLE hLISRData)
{
	return OSUninstallSystemLISR(hLISRData);
}

PVRSRV_ERROR SysDebugInfo(PVRSRV_DEVICE_CONFIG *psDevConfig,
				DUMPDEBUG_PRINTF_FUNC *pfnDumpDebugPrintf,
				void *pvDumpDebugFile)
{
	PVR_UNREFERENCED_PARAMETER(psDevConfig);
	PVR_UNREFERENCED_PARAMETER(pfnDumpDebugPrintf);
	PVR_UNREFERENCED_PARAMETER(pvDumpDebugFile);
	return PVRSRV_OK;
}

/*
 * do_invalid_range — DDK 1.19 common code (dma_support.c, rgxlayer_impl.c)
 * calls this after standard cache maintenance for an extra cache flush.
 *
 * The sf_7110 (RISC-V SiFive) implementation allocates a 2 MB zero page and
 * flushes it through the SiFive L2 cache controller — a workaround for the
 * SiFive non-coherent L2 that the Linux DMA API does not fully handle.
 * The start/len parameters are ignored by that implementation (always 0x0,
 * 0x200000).
 *
 * On ARM64 Cortex-A53 (A133), the standard Linux DMA API and the DDK's own
 * OSCPUCache*RangeKM / OSCPUOperation cache-op paths already call the correct
 * ARM64 cache maintenance instructions (__flush_dcache_area / __dma_flush_area).
 * There is no separate L2 cache controller requiring a manual flush — the A53's
 * unified cache hierarchy is maintained coherently by the kernel.
 *
 * The vendor pvrsrvkm.ko (DDK 1.11) does not contain this symbol at all —
 * the DDK 1.11 dma_support.c did not call it.  A no-op is therefore the
 * correct ARM64 implementation: any cache maintenance that matters has already
 * been done by the callers before reaching this point.
 */
void do_invalid_range(unsigned long start, unsigned long len)
{
	/* No-op on ARM64: standard cache maintenance is sufficient. */
	(void)start;
	(void)len;
}

/******************************************************************************
 End of file (sysconfig.c)
******************************************************************************/

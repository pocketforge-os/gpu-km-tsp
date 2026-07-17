/*************************************************************************/ /*!
@File           dc_null.c
@Copyright      Copyright (c) Imagination Technologies Ltd. All Rights Reserved
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
 * PocketForge dc_null — a minimal, hardware-free "null" Display Class backend.
 *
 * WHY THIS EXISTS
 * ---------------
 * On mainline (6.x) the A133 GPU KM is built PVR_HEADLESS_NO_DC=1, so the
 * fbdev-bound dc_sunxi Display-Class backend is excluded (it hard-depends on
 * registered_fb[]/CONFIG_FB, obsolete on a DRM/KMS mainline kernel). That
 * leaves ZERO registered DC devices — and the closed vendor NULL_WSEGL
 * usermode blob (BVNC 22.102.54.38) does NOT tolerate that: its
 * WSEGL_InitialiseDisplay (invoked at eglInitialize, before ANY surface is
 * created) does:
 *     PVRSRVConnect
 *   → PVRSRVDCDevicesQueryCount   (>=1, else it manufactures error 187)
 *   → PVRSRVDCDevicesEnumerate    (>=1 handle, else 187)
 *   → PVRSRVDCDeviceAcquire
 *   → PVRSRVDCGetInfo
 *   → PVRSRVDCPanelQueryCount     (>=1, else the SAME 187)
 *   → PVRSRVDCPanelQuery
 *   → PVRSRVDCFormatQuery         (>=1 format, else error 272)
 *   → PVRSRVDCDimQuery            (>=1 dim,    else error 275)
 *   → RGXCreateDeviceMemContext
 * With zero DC devices the QueryCount==0 path fires and the UM synthesizes
 * PVRSRV_ERROR_NO_DC_DEVICES_FOUND *entirely in userspace* (no ioctl, no
 * dmesg line) → eglInitialize returns EGL_NOT_INITIALIZED (0x3001). That is
 * the exact silent mainline A2 render blocker root-caused under tsp-mc9m.9
 * round-7 (device-free: KM-source + read-only blob disasm). It is NOT new:
 * commit 576a8ef (tsp-cv7.4.3) hit and fixed this same silent eglInitialize
 * failure on vendor 4.9 (disasm + on-device verified), where the fix path
 * involved getting DCDevicesQueryCount to report a real dc_sunxi device.
 *
 * The disasm also proved the discriminating fact for choosing a fix: every
 * DC call WSEGL_InitialiseDisplay makes is QUERY-ONLY — it never calls
 * DCSystemBufferAcquire / DCDisplayContextCreate / DCBufferAlloc /
 * DCContextConfigure, and an offscreen pbuffer surface never touches the
 * WSEGL vtable at all. So NO real scanout / display-buffer / flip is needed
 * to get past eglInitialize and render a headless pbuffer. A DC backend that
 * merely *registers* one device and answers the query callbacks with one
 * synthetic panel/format/dimension is sufficient — which is what this module
 * is. This is the coordinator + device-broker ratified "Path A" for the A2
 * bar; the full DRM/KMS display path stays a separate display epic (Path B).
 *
 * REUSE
 * -----
 * A hardware-free DC is durable headless-GPU-CI infrastructure: it lets the
 * closed GLES/EGL stack initialise and run offscreen renders with no panel,
 * which is exactly what a headless GPU regression target needs (HIL lane,
 * tsp-147u.8). Hence this is its own owned module (bead tsp-mc9m.11), not a
 * throwaway shim.
 *
 * DESIGN NOTES
 * ------------
 * - No CONFIG_FB / linux/fb.h dependency. Registration is a single
 *   DCRegisterDevice() call from module_init; teardown is DCUnregisterDevice().
 * - The five mandatory query callbacks return a hardcoded synthetic panel
 *   (DC_NULL_WIDTH x DC_NULL_HEIGHT, one pixel format, one dimension).
 * - PIXEL FORMAT IS DELIBERATELY B8G8R8X8_UNORM (IMG_PIXFMT enum 90), NOT
 *   B8G8R8A8_UNORM (89). The closed UM's render-target classifier (libGLESv2)
 *   recognises 90 but treats 89 as unrecognised → a zero render-target
 *   word-count that underflows into an OOB stack read and SIGSEGVs libusc at
 *   shader-compile / makeCurrent. This was root-caused in the dc_sunxi
 *   FORCE_XRGB8888 history (tsp-cv7.4.3); we mirror the proven format so the
 *   pbuffer render path stays clean.
 * - The mandatory context/buffer callbacks are provided (non-NULL, since
 *   dc_server.c calls them without a NULL guard) but are minimal: this null
 *   backend owns no scanout memory, so BufferAlloc/Acquire return
 *   NOT_IMPLEMENTED. Per the disasm they are NOT reached by the headless
 *   pbuffer path; if a future/real display path DOES reach them, the clean
 *   error is the honest signal that a functional DC (Path B) is required
 *   rather than a silent misbehaviour.
 * - ContextConfigure still calls DCDisplayConfigurationRetired() for every
 *   config (as dc_server's SCP machinery requires) so it is safe if ever hit.
 */

#include <linux/module.h>
#include <linux/slab.h>
#include <linux/string.h>

#include "kerneldisplay.h"
#include "powervr/imgpixfmts.h"
#include "pvrmodule.h" /* for MODULE_LICENSE() */

#define DRVNAME			"dc_null"
#define MAX_COMMANDS_IN_FLIGHT	2

/* Synthetic panel reported to the services/UM stack. No real hardware backs
 * this; the values only have to be internally consistent and non-degenerate
 * so the UM's WSEGL_InitialiseDisplay query gauntlet passes.
 */
#define DC_NULL_WIDTH		1280
#define DC_NULL_HEIGHT		720
#define DC_NULL_REFRESH_HZ	60
#define DC_NULL_DPI		160
/* See DESIGN NOTES: 90 (B8G8R8X8) is UM-recognised; 89 (B8G8R8A8) is not. */
#define DC_NULL_PIXFMT		IMG_PIXFMT_B8G8R8X8_UNORM

typedef struct _DC_NULL_DEVICE_
{
	IMG_HANDLE	hSrvHandle;	/* handle from DCRegisterDevice, for unregister */
	IMG_PIXFMT	ePixFormat;
	IMG_UINT32	ui32Width;
	IMG_UINT32	ui32Height;
}
DC_NULL_DEVICE;

typedef struct _DC_NULL_CONTEXT_
{
	DC_NULL_DEVICE	*psDeviceData;
	IMG_HANDLE	 hLastConfigData;
}
DC_NULL_CONTEXT;

static DC_NULL_DEVICE *gpsDeviceData;

/* ------------------------------------------------------------------ */
/* Mandatory query callbacks (the ones WSEGL_InitialiseDisplay drives) */
/* ------------------------------------------------------------------ */

static
void DC_NULL_GetInfo(IMG_HANDLE hDeviceData,
					 DC_DISPLAY_INFO *psDisplayInfo)
{
	PVR_UNREFERENCED_PARAMETER(hDeviceData);

	strncpy(psDisplayInfo->szDisplayName, DRVNAME " 1", DC_NAME_SIZE);
	psDisplayInfo->szDisplayName[DC_NAME_SIZE - 1] = '\0';

	psDisplayInfo->ui32MinDisplayPeriod	= 0;
	psDisplayInfo->ui32MaxDisplayPeriod	= 1;
	psDisplayInfo->ui32MaxPipes		= 1;
	psDisplayInfo->bUnlatchedSupported	= IMG_FALSE;
}

static
PVRSRV_ERROR DC_NULL_PanelQueryCount(IMG_HANDLE hDeviceData,
					 IMG_UINT32 *pui32NumPanels)
{
	PVR_UNREFERENCED_PARAMETER(hDeviceData);
	*pui32NumPanels = 1;
	return PVRSRV_OK;
}

static
PVRSRV_ERROR DC_NULL_PanelQuery(IMG_HANDLE hDeviceData,
				IMG_UINT32 ui32PanelsArraySize,
				IMG_UINT32 *pui32NumPanels,
				PVRSRV_PANEL_INFO *psPanelInfo)
{
	DC_NULL_DEVICE *psDeviceData = hDeviceData;

	if (ui32PanelsArraySize < 1)
	{
		*pui32NumPanels = 0;
		return PVRSRV_OK;
	}

	*pui32NumPanels = 1;

	psPanelInfo[0].sSurfaceInfo.sDims.ui32Width	= psDeviceData->ui32Width;
	psPanelInfo[0].sSurfaceInfo.sDims.ui32Height	= psDeviceData->ui32Height;
	psPanelInfo[0].sSurfaceInfo.sFormat.ePixFormat	= psDeviceData->ePixFormat;
	psPanelInfo[0].sSurfaceInfo.sFormat.eMemLayout	= PVRSRV_SURFACE_MEMLAYOUT_STRIDED;
	psPanelInfo[0].sSurfaceInfo.sFormat.u.sFBCLayout.eFBCompressionMode =
		IMG_FB_COMPRESSION_NONE;
	psPanelInfo[0].sSurfaceInfo.ui32FBCBaseOffset	= 0;

	psPanelInfo[0].ui32RefreshRate	= DC_NULL_REFRESH_HZ;
	psPanelInfo[0].ui32XDpi		= DC_NULL_DPI;
	psPanelInfo[0].ui32YDpi		= DC_NULL_DPI;

	return PVRSRV_OK;
}

static
PVRSRV_ERROR DC_NULL_FormatQuery(IMG_HANDLE hDeviceData,
				 IMG_UINT32 ui32NumFormats,
				 PVRSRV_SURFACE_FORMAT *pasFormat,
				 IMG_UINT32 *pui32Supported)
{
	DC_NULL_DEVICE *psDeviceData = hDeviceData;
	IMG_UINT32 i;

	for (i = 0; i < ui32NumFormats; i++)
	{
		pui32Supported[i] =
			(pasFormat[i].ePixFormat == psDeviceData->ePixFormat) ? 1 : 0;
	}

	return PVRSRV_OK;
}

static
PVRSRV_ERROR DC_NULL_DimQuery(IMG_HANDLE hDeviceData,
				  IMG_UINT32 ui32NumDims,
				  PVRSRV_SURFACE_DIMS *pasDim,
				  IMG_UINT32 *pui32Supported)
{
	DC_NULL_DEVICE *psDeviceData = hDeviceData;
	IMG_UINT32 i;

	for (i = 0; i < ui32NumDims; i++)
	{
		pui32Supported[i] =
			(pasDim[i].ui32Width  == psDeviceData->ui32Width &&
			 pasDim[i].ui32Height == psDeviceData->ui32Height) ? 1 : 0;
	}

	return PVRSRV_OK;
}

/* ------------------------------------------------------------------ */
/* Mandatory context callbacks (non-NULL; not reached by the headless  */
/* pbuffer path, but dc_server calls them without a NULL guard)         */
/* ------------------------------------------------------------------ */

static
PVRSRV_ERROR DC_NULL_ContextCreate(IMG_HANDLE hDeviceData,
				   IMG_HANDLE *hDisplayContext)
{
	DC_NULL_CONTEXT *psDeviceContext;

	psDeviceContext = kzalloc(sizeof(DC_NULL_CONTEXT), GFP_KERNEL);
	if (!psDeviceContext)
	{
		return PVRSRV_ERROR_OUT_OF_MEMORY;
	}

	psDeviceContext->psDeviceData	 = hDeviceData;
	psDeviceContext->hLastConfigData = NULL;
	*hDisplayContext = psDeviceContext;

	return PVRSRV_OK;
}

static
void DC_NULL_ContextConfigure(IMG_HANDLE hDisplayContext,
				  IMG_UINT32 ui32PipeCount,
				  PVRSRV_SURFACE_CONFIG_INFO *pasSurfAttrib,
				  IMG_HANDLE *ahBuffers,
				  IMG_UINT32 ui32DisplayPeriod,
				  IMG_HANDLE hConfigData)
{
	DC_NULL_CONTEXT *psDeviceContext = hDisplayContext;

	PVR_UNREFERENCED_PARAMETER(pasSurfAttrib);
	PVR_UNREFERENCED_PARAMETER(ahBuffers);
	PVR_UNREFERENCED_PARAMETER(ui32DisplayPeriod);

	/* No scanout: there is nothing to present. We only have to drive the
	 * DC core's retire handshake so the SCP command completes.
	 */
	if (psDeviceContext->hLastConfigData)
	{
		DCDisplayConfigurationRetired(psDeviceContext->hLastConfigData);
	}

	if (ui32PipeCount != 0)
	{
		psDeviceContext->hLastConfigData = hConfigData;
	}
	else
	{
		/* Tear-down flip: record nothing, but still retire this NULL
		 * config so the DC core can destroy the display context.
		 */
		psDeviceContext->hLastConfigData = NULL;
		DCDisplayConfigurationRetired(hConfigData);
	}
}

static
void DC_NULL_ContextDestroy(IMG_HANDLE hDisplayContext)
{
	DC_NULL_CONTEXT *psDeviceContext = hDisplayContext;

	BUG_ON(psDeviceContext->hLastConfigData != NULL);
	kfree(psDeviceContext);
}

/* ------------------------------------------------------------------ */
/* Mandatory buffer callbacks (non-NULL stubs; a null DC owns no        */
/* scanout memory. Per the round-7 disasm these are NOT hit by the      */
/* headless pbuffer path — a clean NOT_IMPLEMENTED here is the honest    */
/* signal that a real display backend (Path B) would be required.)      */
/* ------------------------------------------------------------------ */

static
PVRSRV_ERROR DC_NULL_BufferAlloc(IMG_HANDLE hDisplayContext,
				 DC_BUFFER_CREATE_INFO *psCreateInfo,
				 IMG_DEVMEM_LOG2ALIGN_T *puiLog2PageSize,
				 IMG_UINT32 *pui32PageCount,
				 IMG_UINT32 *pui32PhysHeapID,
				 IMG_UINT32 *pui32ByteStride,
				 IMG_HANDLE *phBuffer)
{
	PVR_UNREFERENCED_PARAMETER(hDisplayContext);
	PVR_UNREFERENCED_PARAMETER(psCreateInfo);
	PVR_UNREFERENCED_PARAMETER(puiLog2PageSize);
	PVR_UNREFERENCED_PARAMETER(pui32PageCount);
	PVR_UNREFERENCED_PARAMETER(pui32PhysHeapID);
	PVR_UNREFERENCED_PARAMETER(pui32ByteStride);
	PVR_UNREFERENCED_PARAMETER(phBuffer);

	pr_err(DRVNAME ": BufferAlloc called on a null (scanout-less) DC — a "
		   "real display buffer is not available; a functional DC backend "
		   "is required for this path.\n");
	return PVRSRV_ERROR_NOT_IMPLEMENTED;
}

static
PVRSRV_ERROR DC_NULL_BufferAcquire(IMG_HANDLE hBuffer,
				   IMG_DEV_PHYADDR *pasDevPAddr,
				   void **ppvLinAddr)
{
	PVR_UNREFERENCED_PARAMETER(hBuffer);
	PVR_UNREFERENCED_PARAMETER(pasDevPAddr);
	PVR_UNREFERENCED_PARAMETER(ppvLinAddr);
	return PVRSRV_ERROR_NOT_IMPLEMENTED;
}

static
void DC_NULL_BufferRelease(IMG_HANDLE hBuffer)
{
	PVR_UNREFERENCED_PARAMETER(hBuffer);
}

static
void DC_NULL_BufferFree(IMG_HANDLE hBuffer)
{
	PVR_UNREFERENCED_PARAMETER(hBuffer);
}

/* ------------------------------------------------------------------ */
/* Module init/exit                                                    */
/* ------------------------------------------------------------------ */

static int __init DC_NULL_init(void)
{
	static DC_DEVICE_FUNCTIONS sDCFunctions =
	{
		.pfnGetInfo		= DC_NULL_GetInfo,
		.pfnPanelQueryCount	= DC_NULL_PanelQueryCount,
		.pfnPanelQuery		= DC_NULL_PanelQuery,
		.pfnFormatQuery		= DC_NULL_FormatQuery,
		.pfnDimQuery		= DC_NULL_DimQuery,
		.pfnSetBlank		= NULL,
		.pfnSetVSyncReporting	= NULL,
		.pfnLastVSyncQuery	= NULL,
		.pfnContextCreate	= DC_NULL_ContextCreate,
		.pfnContextDestroy	= DC_NULL_ContextDestroy,
		.pfnContextConfigure	= DC_NULL_ContextConfigure,
		.pfnContextConfigureCheck = NULL,
		.pfnBufferAlloc		= DC_NULL_BufferAlloc,
		.pfnBufferAcquire	= DC_NULL_BufferAcquire,
		.pfnBufferRelease	= DC_NULL_BufferRelease,
		.pfnBufferFree		= DC_NULL_BufferFree,
	};

	DC_NULL_DEVICE *psDeviceData;
	PVRSRV_ERROR eError;

	psDeviceData = kzalloc(sizeof(DC_NULL_DEVICE), GFP_KERNEL);
	if (!psDeviceData)
	{
		return -ENOMEM;
	}

	psDeviceData->ePixFormat = DC_NULL_PIXFMT;
	psDeviceData->ui32Width	 = DC_NULL_WIDTH;
	psDeviceData->ui32Height = DC_NULL_HEIGHT;

	eError = DCRegisterDevice(&sDCFunctions,
				  MAX_COMMANDS_IN_FLIGHT,
				  psDeviceData,
				  &psDeviceData->hSrvHandle);
	if (eError != PVRSRV_OK)
	{
		pr_err(DRVNAME ": DCRegisterDevice failed (%d)\n", eError);
		kfree(psDeviceData);
		return -ENODEV;
	}

	gpsDeviceData = psDeviceData;

	pr_info(DRVNAME ": registered null Display Class device "
			"(%ux%u, pixfmt %u, headless/no-scanout)\n",
			psDeviceData->ui32Width, psDeviceData->ui32Height,
			psDeviceData->ePixFormat);
	return 0;
}

static void __exit DC_NULL_exit(void)
{
	DC_NULL_DEVICE *psDeviceData = gpsDeviceData;

	if (!psDeviceData)
	{
		return;
	}

	DCUnregisterDevice(psDeviceData->hSrvHandle);
	kfree(psDeviceData);
	gpsDeviceData = NULL;
}

module_init(DC_NULL_init);
module_exit(DC_NULL_exit);

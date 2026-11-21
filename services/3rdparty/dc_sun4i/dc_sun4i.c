/*************************************************************************/ /*!
@File           dc_sun4i.c
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

/*!
 * dc_sun4i: fbdev-to-PVR-DC bridge for sun4i-drm on Linux 7.2
 *
 * This module binds to the fbdev device exposed by sun4i-drm's fbdev emulation.
 * It discovers the fb_info through the public DRM path (drm_device->fb_helper->info)
 * rather than the private registered_fb[] array (which became private in Linux 7.2).
 *
 * The module implements the PVR Display Class API to allow the closed usermode
 * DDK blobs to present rendered frames through the sun4i-drm scanout.
 *
 * Design seam: DRM fbdev emulation (not KMS atomic). Evidence:
 *   - sun4i-drm uses DRM_FBDEV_DMA_DRIVER_OPS which creates fb_helper
 *   - dc_sunxi (4.9 BSP) used registered_fb[] directly; 7.2 requires DRM path
 *   - Build system checks CONFIG_DRM_FBDEV_EMULATION; falls back to dc_null if absent
 *   - KMS atomic would require rewriting the entire DC API against drm_crtc/
 *     drm_plane, which is a much larger change with no standalone acceptance
 *     value in one bounded worker.
 *
 * This is functionally equivalent to dc_sunxi but targets the mainline sun4i-drm
 * driver on Linux 7.2 rather than the legacy sunxi disp driver on 4.9 BSP.
 */

#include <linux/console.h>
#include <linux/module.h>
#include <linux/fb.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <drm/drm_device.h>
#include <drm/drm_fb_helper.h>

#include "kerneldisplay.h"
#include "powervr/imgpixfmts.h"
#include "pvrmodule.h" /* for MODULE_LICENSE() */

#if !defined(CONFIG_DRM_FBDEV_EMULATION)
#error dc_sun4i needs DRM fbdev emulation. Enable CONFIG_DRM_FBDEV_EMULATION in your kernel.
#endif

#define DRVNAME					"dc_sun4i"
#define DC_PHYS_HEAP_ID			0
#define MAX_COMMANDS_IN_FLIGHT	2

#if defined(DC_SUN4I_NUM_PREFERRED_BUFFERS)
#define NUM_PREFERRED_BUFFERS	DC_SUN4I_NUM_PREFERRED_BUFFERS
#else
#define NUM_PREFERRED_BUFFERS	2
#endif

#define FALLBACK_REFRESH_RATE		60
#define FALLBACK_DPI		        160

typedef struct
{
	IMG_HANDLE			hSrvHandle;
	IMG_UINT32			ePixFormat;
	struct fb_info		*psLINFBInfo;
	bool				bCanFlip;
}
DC_SUN4I_DEVICE;

typedef struct
{
	DC_SUN4I_DEVICE		*psDeviceData;
	IMG_HANDLE			hLastConfigData;
	IMG_UINT32		ui32AllocUseMask;
}
DC_SUN4I_CONTEXT;

typedef struct
{
	DC_SUN4I_CONTEXT	*psDeviceContext;
	IMG_UINT32			ui32Width;
	IMG_UINT32			ui32Height;
	IMG_UINT32			ui32ByteStride;
	IMG_UINT32			ui32BufferID;
}
DC_SUN4I_BUFFER;

static DC_SUN4I_DEVICE *gpsDeviceData;

/*
 * dc_sun4i_find_fb_info - Discover fb_info via DRM device on Linux 7.2+
 *
 * In Linux 7.2, registered_fb[] is private to fbdev-core. We discover the
 * fb_info through the public DRM path: find the sun4i-drm platform device,
 * get its drm_device, and access fb_helper->info.
 *
 * Returns fb_info pointer on success, NULL on failure.
 */
static struct fb_info *dc_sun4i_find_fb_info(void)
{
	struct device_node *np;
	struct platform_device *pdev;
	struct device *dev;
	struct drm_device *drm;
	struct fb_info *info = NULL;

	/* Find the sun4i-drm device by compatible string */
	np = of_find_compatible_node(NULL, NULL, "allwinner,sun4i-a10-display-engine");
	if (!np) {
		/* Try A33-specific compatible */
		np = of_find_compatible_node(NULL, NULL, "allwinner,sun8i-a33-display-engine");
	}
	if (!np) {
		pr_err("dc_sun4i: no compatible sun4i-drm device found\n");
		return NULL;
	}

	/* Get the platform device from the device node */
	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!pdev) {
		pr_err("dc_sun4i: no platform device for sun4i-drm\n");
		return NULL;
	}

	/* Get the drm_device from platform device drvdata */
	dev = &pdev->dev;
	drm = dev_get_drvdata(dev);
	if (!drm) {
		pr_err("dc_sun4i: no drm_device in drvdata\n");
		return NULL;
	}

	/* Access fb_info through drm_fb_helper (public fields) */
	if (!drm->fb_helper) {
		pr_err("dc_sun4i: no fb_helper in drm_device\n");
		return NULL;
	}

	info = drm->fb_helper->info;
	if (!info) {
		pr_err("dc_sun4i: no fb_info in fb_helper\n");
		return NULL;
	}

	return info;
}


static
void DC_SUN4I_GetInfo(IMG_HANDLE hDeviceData,
						  DC_DISPLAY_INFO *psDisplayInfo)
{
	PVR_UNREFERENCED_PARAMETER(hDeviceData);

	strscpy(psDisplayInfo->szDisplayName, DRVNAME " 1", DC_NAME_SIZE);

	psDisplayInfo->ui32MinDisplayPeriod	= 0;
	psDisplayInfo->ui32MaxDisplayPeriod	= 1;
	psDisplayInfo->ui32MaxPipes			= 1;
	psDisplayInfo->bUnlatchedSupported	= IMG_FALSE;
}

static
PVRSRV_ERROR DC_SUN4I_PanelQueryCount(IMG_HANDLE hDeviceData,
									  IMG_UINT32 *pui32NumPanels)
{
	PVR_UNREFERENCED_PARAMETER(hDeviceData);
	*pui32NumPanels = 1;
	return PVRSRV_OK;
}

static
PVRSRV_ERROR DC_SUN4I_PanelQuery(IMG_HANDLE hDeviceData,
								 IMG_UINT32 ui32PanelsArraySize,
								 IMG_UINT32 *pui32NumPanels,
								 PVRSRV_PANEL_INFO *psPanelInfo)
{
	DC_SUN4I_DEVICE *psDeviceData = hDeviceData;
	struct fb_var_screeninfo *psVar = &psDeviceData->psLINFBInfo->var;
	struct fb_var_screeninfo sVar = { .pixclock = 0 };

	/* Linux 7.2: lock_fb_info is void, always succeeds */
	lock_fb_info(psDeviceData->psLINFBInfo);

	*pui32NumPanels = 1;

	psPanelInfo[0].sSurfaceInfo.sFormat.ePixFormat = psDeviceData->ePixFormat;
	psPanelInfo[0].sSurfaceInfo.sDims.ui32Width    = psVar->xres;
	psPanelInfo[0].sSurfaceInfo.sDims.ui32Height   = psVar->yres;
	psPanelInfo[0].sSurfaceInfo.sFormat.eMemLayout = PVRSRV_SURFACE_MEMLAYOUT_STRIDED;
	psPanelInfo[0].sSurfaceInfo.sFormat.u.sFBCLayout.eFBCompressionMode = IMG_FB_COMPRESSION_NONE;

	/* Conformant fbdev drivers should have `var' and mode in sync by now,
	 * but some don't (like drmfb), so try a couple of different ways to
	 * get the info before falling back to the default.
	 */
	if(psVar->xres > 0 && psVar->yres > 0 && psVar->pixclock > 0)
		sVar = *psVar;
	else if(psDeviceData->psLINFBInfo->mode)
		fb_videomode_to_var(&sVar, psDeviceData->psLINFBInfo->mode);

	/* Override the refresh rate when defined. */
#ifdef DC_SUN4I_REFRESH
	psPanelInfo[0].ui32RefreshRate = DC_SUN4I_REFRESH;
#else
	if(sVar.xres > 0 && sVar.yres > 0 && sVar.pixclock > 0)
	{
		psPanelInfo[0].ui32RefreshRate = 1000000000LU /
			((sVar.upper_margin + sVar.lower_margin +
			  sVar.yres + sVar.vsync_len) *
			 (sVar.left_margin  + sVar.right_margin +
			  sVar.xres + sVar.hsync_len) *
			 (sVar.pixclock / 1000));
	}
	else
		psPanelInfo[0].ui32RefreshRate = FALLBACK_REFRESH_RATE;
#endif

	psPanelInfo[0].ui32XDpi =
		((int)sVar.width > 0) ? (254000 / sVar.width * psVar->xres / 10000) : FALLBACK_DPI;

	psPanelInfo[0].ui32YDpi	=
		((int)sVar.height > 0) ? 254000 / sVar.height * psVar->yres / 10000 : FALLBACK_DPI;

	unlock_fb_info(psDeviceData->psLINFBInfo);
	return PVRSRV_OK;
}

static
PVRSRV_ERROR DC_SUN4I_FormatQuery(IMG_HANDLE hDeviceData,
								  IMG_UINT32 ui32NumFormats,
								  PVRSRV_SURFACE_FORMAT *pasFormat,
								  IMG_UINT32 *pui32Supported)
{
	DC_SUN4I_DEVICE *psDeviceData = hDeviceData;
	int i;

	for(i = 0; i < ui32NumFormats; i++)
	{
		pui32Supported[i] = 0;

		if(pasFormat[i].ePixFormat == psDeviceData->ePixFormat)
			pui32Supported[i]++;
	}

	return PVRSRV_OK;
}

static
PVRSRV_ERROR DC_SUN4I_DimQuery(IMG_HANDLE hDeviceData,
							   IMG_UINT32 ui32NumDims,
							   PVRSRV_SURFACE_DIMS *psDim,
							   IMG_UINT32 *pui32Supported)
{
	DC_SUN4I_DEVICE *psDeviceData = hDeviceData;
	struct fb_var_screeninfo *psVar = &psDeviceData->psLINFBInfo->var;
	int i;

	/* Linux 7.2: lock_fb_info is void, always succeeds */
	lock_fb_info(psDeviceData->psLINFBInfo);

	for(i = 0; i < ui32NumDims; i++)
	{
		pui32Supported[i] = 0;

		if(psDim[i].ui32Width  == psVar->xres &&
		   psDim[i].ui32Height == psVar->yres)
			pui32Supported[i]++;
	}

	unlock_fb_info(psDeviceData->psLINFBInfo);
	return PVRSRV_OK;
}

static
PVRSRV_ERROR DC_SUN4I_ContextCreate(IMG_HANDLE hDeviceData,
									IMG_HANDLE *hDisplayContext)
{
	DC_SUN4I_CONTEXT *psDeviceContext;
	PVRSRV_ERROR eError = PVRSRV_OK;

	psDeviceContext = kzalloc(sizeof(DC_SUN4I_CONTEXT), GFP_KERNEL);
	if(!psDeviceContext)
	{
		eError = PVRSRV_ERROR_OUT_OF_MEMORY;
		goto err_out;
	}

	psDeviceContext->psDeviceData = hDeviceData;
	*hDisplayContext = psDeviceContext;

err_out:
	return eError;
}

static PVRSRV_ERROR
DC_SUN4I_ContextConfigureCheck(IMG_HANDLE hDisplayContext,
							   IMG_UINT32 ui32PipeCount,
							   PVRSRV_SURFACE_CONFIG_INFO *pasSurfAttrib,
							   IMG_HANDLE *ahBuffers)
{
	DC_SUN4I_CONTEXT *psDeviceContext = hDisplayContext;
	DC_SUN4I_DEVICE *psDeviceData = psDeviceContext->psDeviceData;
	struct fb_var_screeninfo *psVar = &psDeviceData->psLINFBInfo->var;
	DC_SUN4I_BUFFER *psBuffer;
	PVRSRV_ERROR eError;

	if(ui32PipeCount != 1)
	{
		eError = PVRSRV_ERROR_DC_TOO_MANY_PIPES;
		goto err_out;
	}

	if(!ahBuffers)
	{
		eError = PVRSRV_ERROR_DC_INVALID_CONFIG;
		goto err_out;
	}

	/* Linux 7.2: lock_fb_info is void, always succeeds */
	lock_fb_info(psDeviceData->psLINFBInfo);

	psBuffer = ahBuffers[0];

	if(pasSurfAttrib[0].sCrop.sDims.ui32Width  != psVar->xres ||
	   pasSurfAttrib[0].sCrop.sDims.ui32Height != psVar->yres ||
	   pasSurfAttrib[0].sCrop.i32XOffset != 0 ||
	   pasSurfAttrib[0].sCrop.i32YOffset != 0)
	{
		eError = PVRSRV_ERROR_DC_INVALID_CROP_RECT;
		goto err_unlock;
	}

	if(pasSurfAttrib[0].sDisplay.sDims.ui32Width !=
	   pasSurfAttrib[0].sCrop.sDims.ui32Width ||
	   pasSurfAttrib[0].sDisplay.sDims.ui32Height !=
	   pasSurfAttrib[0].sCrop.sDims.ui32Height ||
	   pasSurfAttrib[0].sDisplay.i32XOffset !=
	   pasSurfAttrib[0].sCrop.i32XOffset ||
	   pasSurfAttrib[0].sDisplay.i32YOffset !=
	   pasSurfAttrib[0].sCrop.i32YOffset)
	{
		eError = PVRSRV_ERROR_DC_INVALID_DISPLAY_RECT;
		goto err_unlock;
	}

	if(psBuffer->ui32Width  != psVar->xres ||
	   psBuffer->ui32Height != psVar->yres)
	{
		eError = PVRSRV_ERROR_DC_INVALID_BUFFER_DIMS;
		goto err_unlock;
	}

	eError = PVRSRV_OK;
err_unlock:
	unlock_fb_info(psDeviceData->psLINFBInfo);
err_out:
	return eError;
}

static
void DC_SUN4I_ContextConfigure(IMG_HANDLE hDisplayContext,
								   IMG_UINT32 ui32PipeCount,
								   PVRSRV_SURFACE_CONFIG_INFO *pasSurfAttrib,
								   IMG_HANDLE *ahBuffers,
								   IMG_UINT32 ui32DisplayPeriod,
								   IMG_HANDLE hConfigData)
{
	DC_SUN4I_CONTEXT *psDeviceContext = hDisplayContext;
	DC_SUN4I_DEVICE *psDeviceData = psDeviceContext->psDeviceData;
	struct fb_var_screeninfo sVar = psDeviceData->psLINFBInfo->var;
	int err;

	PVR_UNREFERENCED_PARAMETER(ui32PipeCount);
	PVR_UNREFERENCED_PARAMETER(pasSurfAttrib);
	PVR_UNREFERENCED_PARAMETER(ui32DisplayPeriod);

	sVar.yoffset = 0;

	if (ui32PipeCount != 0)
	{
		BUG_ON(ahBuffers == NULL);

		if (psDeviceData->bCanFlip)
		{
			DC_SUN4I_BUFFER *psBuffer = ahBuffers[0];
			sVar.yoffset = sVar.yres * psBuffer->ui32BufferID;
		}
	}

#if defined(DC_FBDEV_FORCE_CONTEXT_CLEAN)
	DC_FBDEV_Clean(hDisplayContext, ahBuffers);
#endif

	/* Linux 7.2: lock_fb_info is void, always succeeds */
	lock_fb_info(psDeviceData->psLINFBInfo);

	console_lock();

	/* If we're supposed to be able to flip, but the yres_virtual has been
	 * changed to an unsupported (smaller) value, we need to change it back
	 * (this is a workaround for some Linux fbdev drivers that seem to lose any
	 * modifications to yres_virtual after a blank.)
	 */
	if (psDeviceData->bCanFlip &&
		sVar.yres_virtual < sVar.yres * NUM_PREFERRED_BUFFERS)
	{
		sVar.activate = FB_ACTIVATE_NOW;
		sVar.yres_virtual = sVar.yres * NUM_PREFERRED_BUFFERS;

		err = fb_set_var(psDeviceData->psLINFBInfo, &sVar);
		if (err)
			pr_err("fb_set_var failed (err=%d)\n", err);
	}
	else
	{
		err = fb_pan_display(psDeviceData->psLINFBInfo, &sVar);
		if (err)
			pr_err("fb_pan_display failed (err=%d)\n", err);
	}

	console_unlock();
	unlock_fb_info(psDeviceData->psLINFBInfo);

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
		/* If the pipe count is zero, we're tearing down. Don't record
		 * any new configurations.
		 */
		psDeviceContext->hLastConfigData = NULL;

		/* We still need to "retire" this NULL flip as that signals back to
		 * the DC core that we've finished doing what we need to do and it
		 * can destroy the display context
		 */
		DCDisplayConfigurationRetired(hConfigData);
	}
}

static
void DC_SUN4I_ContextDestroy(IMG_HANDLE hDisplayContext)
{
	DC_SUN4I_CONTEXT *psDeviceContext = hDisplayContext;

	BUG_ON(psDeviceContext->hLastConfigData != NULL);
	kfree(psDeviceContext);
}

static
IMG_BOOL DC_SUN4I_GetBufferID(DC_SUN4I_CONTEXT *psDeviceContext, IMG_UINT32 *pui32BufferID)
{
	IMG_UINT32 ui32BufferID;
	/* If we don't support flipping, allow this code to give every
	 * allocated buffer the same ID. This means that the display
	 * won't be panned, and the same page list will be used for
	 * every allocation.
	 */
	if (!psDeviceContext->psDeviceData->bCanFlip)
	{
		*pui32BufferID = 0;
		return IMG_TRUE;
	}

	for (ui32BufferID = 0; ui32BufferID < NUM_PREFERRED_BUFFERS; ++ui32BufferID)
	{
		if ((psDeviceContext->ui32AllocUseMask & (1UL << ui32BufferID)) == 0)
		{
			psDeviceContext->ui32AllocUseMask |= (1UL << ui32BufferID);
			*pui32BufferID = ui32BufferID;

			return IMG_TRUE;
		}
	}
	return IMG_FALSE;
}

static
void DC_SUN4I_PutBufferID(DC_SUN4I_CONTEXT *psDeviceContext, IMG_UINT32 ui32BufferID)
{
	psDeviceContext->ui32AllocUseMask &= ~(1UL << ui32BufferID);
}

#define BYTE_TO_PAGES(range) (((range) + (PAGE_SIZE - 1)) >> PAGE_SHIFT)

static
PVRSRV_ERROR DC_SUN4I_BufferAlloc(IMG_HANDLE hDisplayContext,
								  DC_BUFFER_CREATE_INFO *psCreateInfo,
								  IMG_DEVMEM_LOG2ALIGN_T *puiLog2PageSize,
								  IMG_UINT32 *pui32PageCount,
								  IMG_UINT32 *pui32PhysHeapID,
								  IMG_UINT32 *pui32ByteStride,
								  IMG_HANDLE *phBuffer)
{
	DC_SUN4I_CONTEXT *psDeviceContext = hDisplayContext;
	DC_SUN4I_DEVICE *psDeviceData = psDeviceContext->psDeviceData;
	PVRSRV_SURFACE_INFO *psSurfInfo = &psCreateInfo->sSurface;
	PVRSRV_ERROR eError;
	DC_SUN4I_BUFFER *psBuffer;
	IMG_UINT32 ui32ByteSize;

	if (psSurfInfo->sFormat.ePixFormat != psDeviceData->ePixFormat)
	{
		eError = PVRSRV_ERROR_UNSUPPORTED_PIXEL_FORMAT;
		goto err_out;
	}

	psBuffer = kmalloc(sizeof(DC_SUN4I_BUFFER), GFP_KERNEL);
	if (!psBuffer)
	{
		eError = PVRSRV_ERROR_OUT_OF_MEMORY;
		goto err_out;
	}

	psBuffer->psDeviceContext = psDeviceContext;
	psBuffer->ui32ByteStride =
		psSurfInfo->sDims.ui32Width * psCreateInfo->ui32BPP;

	psBuffer->ui32Width = psSurfInfo->sDims.ui32Width;
	psBuffer->ui32Height = psSurfInfo->sDims.ui32Height;

	if (!DC_SUN4I_GetBufferID(psDeviceContext, &psBuffer->ui32BufferID))
	{
		eError = PVRSRV_ERROR_OUT_OF_MEMORY;
		goto err_free;
	}

	ui32ByteSize = psBuffer->ui32ByteStride * psBuffer->ui32Height;

	*puiLog2PageSize = PAGE_SHIFT;
	*pui32PageCount	 = BYTE_TO_PAGES(ui32ByteSize);
	*pui32PhysHeapID = DC_PHYS_HEAP_ID;
	*pui32ByteStride = psBuffer->ui32ByteStride;
	*phBuffer	 = psBuffer;

	return PVRSRV_OK;

err_free:
	kfree(psBuffer);

err_out:
	return eError;
}

static
PVRSRV_ERROR DC_SUN4I_BufferAcquire(IMG_HANDLE hBuffer,
									IMG_DEV_PHYADDR *pasDevPAddr,
									void **ppvLinAddr)
{
	DC_SUN4I_BUFFER *psBuffer = hBuffer;
	DC_SUN4I_DEVICE *psDeviceData = psBuffer->psDeviceContext->psDeviceData;
	IMG_UINT32 ui32ByteSize = psBuffer->ui32ByteStride * psBuffer->ui32Height;
	uintptr_t uiStartAddr;
	IMG_UINT32 i, ui32MaxLen;

	/* Linux 7.2's drm_fbdev_dma uses direct DMA mapping, not vmalloc.
	 * fix.smem_start is the DMA/bus address of the framebuffer.
	 * screen_base is a kernel virtual address mapping of the same buffer.
	 * For direct DMA mapping, we use fix.smem_start as the physical address.
	 */
	uiStartAddr = psDeviceData->psLINFBInfo->fix.smem_start;
	
	if (uiStartAddr == 0)
	{
		pr_err("dc_sun4i: fix.smem_start is 0; unsupported framebuffer mapping\n");
		return PVRSRV_ERROR_NOT_SUPPORTED;
	}

	uiStartAddr += psBuffer->ui32BufferID * ui32ByteSize;
	ui32MaxLen = psDeviceData->psLINFBInfo->fix.smem_len -
				 psBuffer->ui32BufferID * ui32ByteSize;

	for (i = 0; i < BYTE_TO_PAGES(ui32ByteSize); i++)
	{
		BUG_ON(i * PAGE_SIZE >= ui32MaxLen);
		pasDevPAddr[i].uiAddr = uiStartAddr + (i * PAGE_SIZE);
	}

	/* We're UMA, so services will do the right thing and make
	 * its own CPU virtual address mapping for the buffer.
	 */
	*ppvLinAddr = NULL;

	return PVRSRV_OK;
}

static void DC_SUN4I_BufferRelease(IMG_HANDLE hBuffer)
{
	PVR_UNREFERENCED_PARAMETER(hBuffer);
}

static void DC_SUN4I_BufferFree(IMG_HANDLE hBuffer)
{
	DC_SUN4I_BUFFER *psBuffer = hBuffer;

	DC_SUN4I_PutBufferID(psBuffer->psDeviceContext, psBuffer->ui32BufferID);

	kfree(psBuffer);
}

/* If we can flip, we need to make sure we have the memory to do so.
 *
 * We'll assume that the fbdev device provides extra space in
 * yres_virtual for panning; xres_virtual is theoretically supported,
 * but it involves more work.
 *
 * If the fbdev device doesn't have yres_virtual > yres, we'll try
 * requesting it before bailing. Userspace applications commonly do
 * this with an FBIOPUT_VSCREENINFO ioctl().
 *
 * Another problem is with a limitation in the services DC -- it
 * needs framebuffers to be page aligned (this is a SW limitation,
 * the HW can support non-page-aligned buffers). So we have to
 * check that stride * height for a single buffer is page aligned.
 */

static bool DC_SUN4I_FlipPossible(struct fb_info *psLINFBInfo)
{
	struct fb_var_screeninfo sVar = psLINFBInfo->var;
	int err;

	if(!psLINFBInfo->fix.xpanstep && !psLINFBInfo->fix.ypanstep &&
	   !psLINFBInfo->fix.ywrapstep)
	{
		pr_err("The fbdev device detected does not support ypan/ywrap. "
			   "Flipping disabled.\n");
		return false;
	}

	if((psLINFBInfo->fix.line_length * sVar.yres) % PAGE_SIZE != 0)
	{
		pr_err("Line length (in bytes) x yres is not a multiple of "
			   "page size. Flipping disabled.\n");
		return false;
	}

	/* We might already have enough space */
	if(sVar.yres * NUM_PREFERRED_BUFFERS <= sVar.yres_virtual)
		return true;

	pr_err("No buffer space for flipping; asking for more.\n");

	sVar.activate = FB_ACTIVATE_NOW;
	sVar.yres_virtual = sVar.yres * NUM_PREFERRED_BUFFERS;

	err = fb_set_var(psLINFBInfo, &sVar);
	if(err)
	{
		pr_err("fb_set_var failed (err=%d). Flipping disabled.\n", err);
		return false;
	}

	if(sVar.yres * NUM_PREFERRED_BUFFERS > sVar.yres_virtual)
	{
		pr_err("Failed to obtain additional buffer space. "
			   "Flipping disabled.\n");
		return false;
	}

	/* Some fbdev drivers allow the yres_virtual modification through,
	 * but don't actually update the fix. We need the fix to be updated
	 * and more memory allocated, so we can actually take advantage of
	 * the increased yres_virtual.
	 */
	if(psLINFBInfo->fix.smem_len < psLINFBInfo->fix.line_length * sVar.yres_virtual)
	{
		pr_err("'fix' not re-allocated with sufficient buffer space. "
			   "Flipping disabled.\n");
		return false;
	}

	return true;
}

static int __init DC_SUN4I_init(void)
{
	static DC_DEVICE_FUNCTIONS sDCFunctions =
	{
		.pfnGetInfo					= DC_SUN4I_GetInfo,
		.pfnPanelQueryCount			= DC_SUN4I_PanelQueryCount,
		.pfnPanelQuery				= DC_SUN4I_PanelQuery,
		.pfnFormatQuery				= DC_SUN4I_FormatQuery,
		.pfnDimQuery				= DC_SUN4I_DimQuery,
		.pfnSetBlank				= NULL,
		.pfnSetVSyncReporting		= NULL,
		.pfnLastVSyncQuery			= NULL,
		.pfnContextCreate			= DC_SUN4I_ContextCreate,
		.pfnContextDestroy			= DC_SUN4I_ContextDestroy,
		.pfnContextConfigure		= DC_SUN4I_ContextConfigure,
		.pfnContextConfigureCheck	= DC_SUN4I_ContextConfigureCheck,
		.pfnBufferAlloc				= DC_SUN4I_BufferAlloc,
		.pfnBufferAcquire			= DC_SUN4I_BufferAcquire,
		.pfnBufferRelease			= DC_SUN4I_BufferRelease,
		.pfnBufferFree				= DC_SUN4I_BufferFree,
	};

	struct fb_info *psLINFBInfo;
	IMG_PIXFMT ePixFormat;
	int err = -ENODEV;

	/* Linux 7.2: Discover fb_info via DRM device path */
	psLINFBInfo = dc_sun4i_find_fb_info();
	if(!psLINFBInfo)
	{
		pr_err("No Linux framebuffer (fbdev) device found via DRM!\n"
			   "Check that sun4i-drm is loaded and fbdev emulation is enabled.\n");
		goto err_out;
	}

	/* Linux 7.2: lock_fb_info is void, always succeeds */
	lock_fb_info(psLINFBInfo);

	console_lock();

	/* Filter out broken FB devices */
	if(!psLINFBInfo->fix.smem_len || !psLINFBInfo->fix.line_length)
	{
		pr_err("The fbdev device detected had a zero smem_len or "
			   "line_length,\nwhich suggests it is a broken driver.\n");
		goto err_unlock;
	}

	if(psLINFBInfo->fix.type != FB_TYPE_PACKED_PIXELS ||
	   psLINFBInfo->fix.visual != FB_VISUAL_TRUECOLOR)
	{
		pr_err("The fbdev device detected is not truecolor with packed "
			   "pixels.\n");
		goto err_unlock;
	}

	if(psLINFBInfo->var.bits_per_pixel == 32)
	{
		if(psLINFBInfo->var.red.length   != 8  ||
		   psLINFBInfo->var.green.length != 8  ||
		   psLINFBInfo->var.blue.length  != 8  ||
		   psLINFBInfo->var.red.offset   != 16 ||
		   psLINFBInfo->var.green.offset != 8  ||
		   psLINFBInfo->var.blue.offset  != 0)
		{
			pr_err("The fbdev device detected uses an unrecognized "
				   "32bit pixel format (%u/%u/%u, %u/%u/%u)\n",
				   psLINFBInfo->var.red.length,
				   psLINFBInfo->var.green.length,
				   psLINFBInfo->var.blue.length,
				   psLINFBInfo->var.red.offset,
				   psLINFBInfo->var.green.offset,
				   psLINFBInfo->var.blue.offset);
			goto err_unlock;
		}
#if defined(DC_SUN4I_FORCE_XRGB8888)
		ePixFormat = IMG_PIXFMT_B8G8R8X8_UNORM;
#else
		ePixFormat = IMG_PIXFMT_B8G8R8A8_UNORM;
#endif
	}
	else if(psLINFBInfo->var.bits_per_pixel == 16)
	{
		if(psLINFBInfo->var.red.length   != 5  ||
		   psLINFBInfo->var.green.length != 6  ||
		   psLINFBInfo->var.blue.length  != 5  ||
		   psLINFBInfo->var.red.offset   != 11 ||
		   psLINFBInfo->var.green.offset != 5  ||
		   psLINFBInfo->var.blue.offset  != 0)
		{
			pr_err("The fbdev device detected uses an unrecognized "
				   "16bit pixel format (%u/%u/%u, %u/%u/%u)\n",
				   psLINFBInfo->var.red.length,
				   psLINFBInfo->var.green.length,
				   psLINFBInfo->var.blue.length,
				   psLINFBInfo->var.red.offset,
				   psLINFBInfo->var.green.offset,
				   psLINFBInfo->var.blue.offset);
			goto err_unlock;
		}
		ePixFormat = IMG_PIXFMT_B5G6R5_UNORM;
	}
	else
	{
		pr_err("The fbdev device detected uses an unsupported "
			   "bpp (%u).\n", psLINFBInfo->var.bits_per_pixel);
		goto err_unlock;
	}

	if(!try_module_get(psLINFBInfo->fbops->owner))
	{
		pr_err("try_module_get() failed");
		goto err_unlock;
	}

	if(psLINFBInfo->fbops->fb_open &&
	   psLINFBInfo->fbops->fb_open(psLINFBInfo, 0) != 0)
	{
		pr_err("fb_open() failed");
		goto err_module_put;
	}

	gpsDeviceData = kmalloc(sizeof(DC_SUN4I_DEVICE), GFP_KERNEL);
	if(!gpsDeviceData)
		goto err_module_put;

	gpsDeviceData->psLINFBInfo = psLINFBInfo;
	gpsDeviceData->ePixFormat = ePixFormat;

	if(DCRegisterDevice(&sDCFunctions,
						MAX_COMMANDS_IN_FLIGHT,
						gpsDeviceData,
						&gpsDeviceData->hSrvHandle) != PVRSRV_OK)
		goto err_kfree;

	gpsDeviceData->bCanFlip = DC_SUN4I_FlipPossible(psLINFBInfo);

	pr_info("Found usable fbdev device (%s):\n"
			"range (physical) = 0x%lx-0x%lx\n"
			"size (bytes)     = 0x%x\n"
			"xres x yres      = %ux%u\n"
			"xres x yres (v)  = %ux%u\n"
			"img pix fmt      = %u\n"
			"flipping?        = %d\n",
			psLINFBInfo->fix.id,
			psLINFBInfo->fix.smem_start,
			psLINFBInfo->fix.smem_start + psLINFBInfo->fix.smem_len,
			psLINFBInfo->fix.smem_len,
			psLINFBInfo->var.xres, psLINFBInfo->var.yres,
			psLINFBInfo->var.xres_virtual, psLINFBInfo->var.yres_virtual,
			ePixFormat, gpsDeviceData->bCanFlip);
	err = 0;
err_unlock:
	console_unlock();
	unlock_fb_info(psLINFBInfo);
err_out:
	return err;
err_kfree:
	kfree(gpsDeviceData);
err_module_put:
	module_put(psLINFBInfo->fbops->owner);
	goto err_unlock;
}

static void __exit DC_SUN4I_exit(void)
{
	DC_SUN4I_DEVICE *psDeviceData = gpsDeviceData;
	struct fb_info *psLINFBInfo = psDeviceData->psLINFBInfo;

	/* Linux 7.2: lock_fb_info is void, always succeeds */
	lock_fb_info(psLINFBInfo);
	console_lock();

    if(psLINFBInfo->fbops->fb_release)
	   psLINFBInfo->fbops->fb_release(psLINFBInfo, 0);

	module_put(psLINFBInfo->fbops->owner);

	console_unlock();
	unlock_fb_info(psLINFBInfo);

	DCUnregisterDevice(psDeviceData->hSrvHandle);
	kfree(psDeviceData);
}

module_init(DC_SUN4I_init);
module_exit(DC_SUN4I_exit);

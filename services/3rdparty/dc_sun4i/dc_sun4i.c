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
#include <linux/device/bus.h>
#include <drm/drm_device.h>
#include <drm/drm_drv.h>
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

/*
 * Framebuffer release state machine (under sFBLock):
 *
 * FB_NONE:            Initial state (no fb_open yet)
 * FB_OPENED:          fb_open succeeded, release not yet attempted
 * FB_RELEASE_IN_PROGRESS: claim made, attempting fb_release
 * FB_RELEASED:        fb_release succeeded (terminal, intentional)
 * FB_RELEASE_TERMINAL: cannot release - device unplugged (terminal, intentional)
 *
 * Transitions (all under sFBLock):
 *   FB_NONE -> FB_OPENED: after successful fb_open
 *   FB_OPENED -> FB_RELEASE_IN_PROGRESS: exactly-once claim by helper
 *   FB_RELEASE_IN_PROGRESS -> FB_RELEASED: after successful fb_release
 *   FB_RELEASE_IN_PROGRESS -> FB_RELEASE_TERMINAL: drm_dev_enter failed
 */
enum eFBReleaseState
{
	FB_NONE = 0,
	FB_OPENED,
	FB_RELEASE_IN_PROGRESS,
	FB_RELEASED,
	FB_RELEASE_TERMINAL
};

typedef struct
{
	IMG_HANDLE			hSrvHandle;
	IMG_UINT32			ePixFormat;
	struct drm_device	*psDRMDev;
	struct fb_info		*psLINFBInfo;
	struct module		*psOwner;	/* Cached fbops->owner; safe after fb_info stale */
	bool				bCanFlip;
	/* Provider unbind lifecycle */
	struct notifier_block	sUnbindNotifier;
	struct platform_device	*psPlatformDev;
	struct mutex		sFBLock;
	enum eFBReleaseState	eFBState;
	bool			bNotifierRegistered;
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
 * Supported compatible strings:
 * - allwinner,sun4i-a10-display-engine (A10/A20)
 * - allwinner,sun8i-a33-display-engine (A33)
 * - allwinner,sun50i-a100-display-engine (A100/A133)
 *
 * Outputs:
 *   @out_drm: drm_device pointer with incremented refcount (caller must drm_dev_put)
 *   @out_info: fb_info pointer (valid while DRM dev ref held + fb_helper alive)
 *
 * Returns 0 on success, negative errno on failure.
 *
 * Lifetime contract (public API):
 *   1. drm_dev_get() on drm_device pins the drm_device struct itself.
 *   2. drm_dev_enter()/exit() synchronizes against drm_dev_unplug() at each access.
 *   3. try_module_get(fbops->owner) pins the fbdev owner module (prevents module unload).
 *   4. The fb_helper pointer inside drm_device is set/cleared by the DRM driver;
 *      drm_dev_enter() returns false if the device has been unplugged, which
 *      prevents access after unplug.
 *
 * Known limitation:
 *   The public Linux 7.2 fbdev API does not provide a way to take a reference
 *   on the fb_info itself or on drm_fb_helper. If the DRM driver calls
 *   drm_fb_helper_fini() without calling drm_dev_unplug() first, the fb_info
 *   could become invalid while the drm_device struct is still alive. For this
 *   device-specific module tightly coupled to sun4i-drm on the same hardware,
 *   the unplug path (which the DRM core drives on unbind) provides the
 *   required synchronization. We check drm_dev_enter() at every runtime
 *   access and refuse operation if it returns false.
 */
static int dc_sun4i_find_fb_info(struct drm_device **out_drm,
				 struct fb_info **out_info)
{
	struct device_node *np = NULL;
	struct platform_device *pdev = NULL;
	struct drm_device *drm;
	struct fb_info *info = NULL;
	int drm_idx;

	*out_drm = NULL;
	*out_info = NULL;

	/* Find the sun4i-drm device by compatible string (A10, A33, or A100) */
	np = of_find_compatible_node(NULL, NULL, "allwinner,sun4i-a10-display-engine");
	if (!np) {
		np = of_find_compatible_node(NULL, NULL, "allwinner,sun8i-a33-display-engine");
	}
	if (!np) {
		/* A133 uses A100 display engine */
		np = of_find_compatible_node(NULL, NULL, "allwinner,sun50i-a100-display-engine");
	}
	if (!np) {
		pr_err("dc_sun4i: no compatible sun4i-drm device found (tried A10/A33/A100)\n");
		return -ENODEV;
	}

	/* Get the platform device from the device node */
	pdev = of_find_device_by_node(np);
	of_node_put(np);
	if (!pdev) {
		pr_err("dc_sun4i: no platform device for sun4i-drm\n");
		return -ENODEV;
	}

	/* Get the drm_device from platform device drvdata */
	drm = dev_get_drvdata(&pdev->dev);
	if (!drm) {
		pr_err("dc_sun4i: no drm_device in drvdata - sun4i-drm not fully initialized\n");
		put_device(&pdev->dev);
		return -ENODEV;
	}

	/* Hold a reference on the drm_device to pin its lifetime */
	drm_dev_get(drm);

	/*
	 * Protect fb_helper/info dereference with drm_dev_enter().
	 * fb_helper is a pointer inside drm_device set/cleared by the DRM driver.
	 * drm_dev_enter() synchronizes against drm_dev_unplug() which is called
	 * on unbind; after unplug, fb_helper may be torn down.
	 */
	if (!drm_dev_enter(drm, &drm_idx)) {
		pr_err("dc_sun4i: DRM device unplugged during discovery\n");
		drm_dev_put(drm);
		put_device(&pdev->dev);
		return -ENODEV;
	}

	/* Access fb_info through drm_fb_helper (public fields) */
	if (!drm->fb_helper) {
		pr_err("dc_sun4i: no fb_helper in drm_device - fbdev emulation not ready\n");
		goto err_exit;
	}

	info = drm->fb_helper->info;
	if (!info) {
		pr_err("dc_sun4i: no fb_info in fb_helper - fbdev not initialized\n");
		goto err_exit;
	}

	/* Success: leave protected section, release platform dev ref.
	 * drm_dev reference held by caller until module exit.
	 */
	drm_dev_exit(drm_idx);
	put_device(&pdev->dev);

	*out_drm = drm;
	*out_info = info;
	return 0;

err_exit:
	drm_dev_exit(drm_idx);
	drm_dev_put(drm);
	put_device(&pdev->dev);
	return -ENODEV;
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
	struct fb_var_screeninfo *psVar;
	struct fb_var_screeninfo sVar = { .pixclock = 0 };
	int drm_idx;

	/* Protect against DRM device unplug */
	if (!drm_dev_enter(psDeviceData->psDRMDev, &drm_idx))
		return PVRSRV_ERROR_DC_DEVICE_INACCESSIBLE;

	psVar = &psDeviceData->psLINFBInfo->var;

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
	drm_dev_exit(drm_idx);
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
	struct fb_var_screeninfo *psVar;
	int i;
	int drm_idx;

	/* Protect against DRM device unplug */
	if (!drm_dev_enter(psDeviceData->psDRMDev, &drm_idx))
		return PVRSRV_ERROR_DC_DEVICE_INACCESSIBLE;

	psVar = &psDeviceData->psLINFBInfo->var;

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
	drm_dev_exit(drm_idx);
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
	struct fb_var_screeninfo *psVar;
	DC_SUN4I_BUFFER *psBuffer;
	PVRSRV_ERROR eError;
	int drm_idx;

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

	/* Protect against DRM device unplug */
	if (!drm_dev_enter(psDeviceData->psDRMDev, &drm_idx)) {
		eError = PVRSRV_ERROR_DC_DEVICE_INACCESSIBLE;
		goto err_out;
	}

	psVar = &psDeviceData->psLINFBInfo->var;

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
	drm_dev_exit(drm_idx);
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
	struct fb_var_screeninfo sVar;
	int err;
	bool drm_entered;
	int drm_idx;

	PVR_UNREFERENCED_PARAMETER(ui32PipeCount);
	PVR_UNREFERENCED_PARAMETER(pasSurfAttrib);
	PVR_UNREFERENCED_PARAMETER(ui32DisplayPeriod);

	/* Protect against DRM device unplug */
	drm_entered = drm_dev_enter(psDeviceData->psDRMDev, &drm_idx);
	if (!drm_entered) {
		pr_err("dc_sun4i: DRM device unplugged during ContextConfigure\n");
		goto out_retire;
	}

	sVar = psDeviceData->psLINFBInfo->var;

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
	drm_dev_exit(drm_idx);

out_retire:
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

		/* We still need to "retire" this NULL flip as that signals back to the
		 * DC core that we've finished doing what we need to do and it
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
	PVRSRV_ERROR eError;
	int drm_idx;

	/* Protect against DRM device unplug */
	if (!drm_dev_enter(psDeviceData->psDRMDev, &drm_idx))
		return PVRSRV_ERROR_DC_DEVICE_INACCESSIBLE;

	/* Linux 7.2's drm_fbdev_dma uses direct DMA mapping, not vmalloc.
	 * fix.smem_start is the DMA/bus address of the framebuffer.
	 * screen_base is a kernel virtual address mapping of the same buffer.
	 * For direct DMA mapping, we use fix.smem_start as the physical address.
	 */
	uiStartAddr = psDeviceData->psLINFBInfo->fix.smem_start;
	
	if (uiStartAddr == 0)
	{
		pr_err("dc_sun4i: fix.smem_start is 0; unsupported framebuffer mapping\n");
		eError = PVRSRV_ERROR_NOT_SUPPORTED;
		goto out;
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
	eError = PVRSRV_OK;

out:
	drm_dev_exit(drm_idx);
	return eError;
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

/*
 * dc_sun4i_fb_release_once - Exactly-once fb_release helper
 *
 * Shared by: notifier callback, init failure unwind, module exit.
 *
 * Lock order (acquire): sFBLock -> lock_fb_info -> console_lock
 * Lock order (release): console_unlock -> unlock_fb_info -> sFBLock unlock
 *
 * State machine under sFBLock:
 *   eFBState == FB_NONE: not opened or already released
 *   eFBState == FB_OPENED: fb_open succeeded, release not yet attempted
 *   eFBState == FB_RELEASE_IN_PROGRESS: claim made, attempting fb_release
 *   eFBState == FB_RELEASED: fb_release succeeded
 *   eFBState == FB_RELEASE_TERMINAL: cannot release (unplugged), intentional
 *
 * Atomic claim under sFBLock ensures exactly-once semantics.
 * Holds sFBLock through the entire operation to serialize concurrent callers.
 *
 * bus_unregister_notifier() synchronizes with running callbacks; it must
 * NEVER be called while holding sFBLock, lock_fb_info, or console_lock.
 */
static void dc_sun4i_fb_release_once(DC_SUN4I_DEVICE *psDeviceData)
{
	struct fb_info *psLINFBInfo;
	int drm_idx;

	mutex_lock(&psDeviceData->sFBLock);

	/* Atomic claim: exactly one caller wins */
	if(psDeviceData->eFBState != FB_OPENED)
	{
		/* Already released, in progress, terminal, or never opened */
		mutex_unlock(&psDeviceData->sFBLock);
		return;
	}
	/* Claim: mark as in-progress before attempting release */
	psDeviceData->eFBState = FB_RELEASE_IN_PROGRESS;

	psLINFBInfo = psDeviceData->psLINFBInfo;

	/* Protect fb_info access against DRM unplug */
	if(!drm_dev_enter(psDeviceData->psDRMDev, &drm_idx))
	{
		/* Device unplugged: cannot safely access fb_info.
		 * Mark as terminal state (intentional, known limitation).
		 * Do NOT set FB_RELEASED since fb_release was not called.
		 */
		psDeviceData->eFBState = FB_RELEASE_TERMINAL;
		mutex_unlock(&psDeviceData->sFBLock);
		return;
	}

	/* Lock order: sFBLock (held) -> lock_fb_info -> console_lock */
	lock_fb_info(psLINFBInfo);
	console_lock();

	if(psLINFBInfo->fbops->fb_release)
		psLINFBInfo->fbops->fb_release(psLINFBInfo, 0);

	/* Release order: console_unlock -> unlock_fb_info */
	console_unlock();
	unlock_fb_info(psLINFBInfo);
	drm_dev_exit(drm_idx);

	/* Mark as successfully released AFTER fb_release completed */
	psDeviceData->eFBState = FB_RELEASED;

	mutex_unlock(&psDeviceData->sFBLock);
}

/*
 * dc_sun4i_unbind_notifier - Handle platform device unbind before DRM teardown
 *
 * When sun4i-drm is unbound (provider unbind), BUS_NOTIFY_UNBIND_DRIVER fires
 * BEFORE sun4i_drv_unbind() calls drm_dev_unregister(). At this point fb_info
 * is still valid, so we can safely call fb_release via the shared helper.
 *
 * The notifier does NOT hold any locks before calling the helper.
 * The helper acquires sFBLock -> lock_fb_info -> console_lock internally.
 */
static int dc_sun4i_unbind_notifier(struct notifier_block *nb,
				    unsigned long action, void *data)
{
	DC_SUN4I_DEVICE *psDeviceData = container_of(nb, DC_SUN4I_DEVICE, sUnbindNotifier);
	struct device *dev = data;

	if(action != BUS_NOTIFY_UNBIND_DRIVER)
		return NOTIFY_DONE;

	/* Match the exact sun4i platform device we bound to */
	if(dev != &psDeviceData->psPlatformDev->dev)
		return NOTIFY_DONE;

	pr_info("dc_sun4i: provider unbind detected, calling fb_release before teardown");
	dc_sun4i_fb_release_once(psDeviceData);

	return NOTIFY_OK;
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

	struct drm_device *psDRMDev = NULL;
	struct fb_info *psLINFBInfo = NULL;
	struct module *psOwner = NULL;
	IMG_PIXFMT ePixFormat = 0;
	int init_drm_idx = 0;
	int err = -ENODEV;

	/* Linux 7.2: Discover fb_info via DRM device path.
	 * On success, psDRMDev has an incremented refcount (drm_dev_get),
	 * which we must release on every exit path.
	 */
	err = dc_sun4i_find_fb_info(&psDRMDev, &psLINFBInfo);
	if(err)
	{
		pr_err("No Linux framebuffer (fbdev) device found via DRM!\n"
			   "Check that sun4i-drm is loaded and fbdev emulation is enabled.\n");
		goto err_out;
	}
	err = -ENODEV; /* Reset for error paths below */

	/* Protect all fb_info accesses with unplug synchronization. */
	if(!drm_dev_enter(psDRMDev, &init_drm_idx))
	{
		pr_err("dc_sun4i: DRM device unplugged during init\n");
		drm_dev_put(psDRMDev);
		goto err_out;
	}

	/* lock_fb_info is void in Linux 7.2, always succeeds */
	lock_fb_info(psLINFBInfo);
	console_lock();

	/* --- From here: must unwind via err_unlock (releases console+fb locks,
	 *     then drm_dev_exit, then drm_dev_put) --- */

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

	/* Cache the fbops owner module reference independently.
	 * This allows balanced module_put in exit without dereferencing
	 * potentially stale fb_info after provider unbind/unplug.
	 */
	psOwner = psLINFBInfo->fbops->owner;
	if(!try_module_get(psOwner))
	{
		pr_err("try_module_get() failed");
		/* Failed get: psOwner set but we DON'T own a reference */
		goto err_unlock;
	}

	/* Allocate device data BEFORE fb_open so all error paths can use shared helper */
	gpsDeviceData = kzalloc(sizeof(DC_SUN4I_DEVICE), GFP_KERNEL);
	if(!gpsDeviceData)
		/* kzalloc failed: we own module reference from try_module_get */
		goto err_module_put;

	/* Initialize mutex and state */
	mutex_init(&gpsDeviceData->sFBLock);
	gpsDeviceData->eFBState = FB_NONE;
	gpsDeviceData->bNotifierRegistered = false;

	/* Get platform device reference for notifier matching */
	gpsDeviceData->psPlatformDev = to_platform_device(psDRMDev->dev);
	get_device(&gpsDeviceData->psPlatformDev->dev);

	/* Set ALL fields BEFORE fb_open/DCRegisterDevice to prevent publication race */
	gpsDeviceData->psLINFBInfo = psLINFBInfo;
	gpsDeviceData->psDRMDev = psDRMDev;
	gpsDeviceData->psOwner = psOwner;
	gpsDeviceData->ePixFormat = ePixFormat;
	gpsDeviceData->bCanFlip = DC_SUN4I_FlipPossible(psLINFBInfo);

	if(psLINFBInfo->fbops->fb_open &&
	   psLINFBInfo->fbops->fb_open(psLINFBInfo, 0) != 0)
	{
		pr_err("fb_open() failed");
		goto err_release_data;
	}
	gpsDeviceData->eFBState = FB_OPENED;

	/* Register platform-bus notifier BEFORE DCRegisterDevice publication.
	 * This ensures fb_release is called before sun4i-drm teardown.
	 * Failure is fatal - we must guarantee fb_release on provider unbind.
	 * bus_unregister_notifier synchronizes with running callbacks.
	 */
	gpsDeviceData->sUnbindNotifier.notifier_call = dc_sun4i_unbind_notifier;
	if(bus_register_notifier(&platform_bus_type, &gpsDeviceData->sUnbindNotifier) != 0)
	{
		pr_err("dc_sun4i: failed to register unbind notifier, cannot guarantee fb_release on unbind");
		goto err_release_helper;
	}
	gpsDeviceData->bNotifierRegistered = true;
	pr_info("dc_sun4i: registered platform-bus unbind notifier");

	/* Now register with PVR services - callbacks may fire immediately */
	if(DCRegisterDevice(&sDCFunctions,
						MAX_COMMANDS_IN_FLIGHT,
						gpsDeviceData,
						&gpsDeviceData->hSrvHandle) != PVRSRV_OK)
		goto err_release_helper;

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
	/* Success: release locks/enter but RETAIN drm_dev reference for exit.
	 * Critical: this path must NOT fall through to err_drm_put.
	 * The drm_dev_get reference is held in gpsDeviceData->psDRMDev until
	 * DC_SUN4I_exit calls drm_dev_put.
	 */
	console_unlock();
	unlock_fb_info(psLINFBInfo);
	drm_dev_exit(init_drm_idx);
	return 0;

/*
 * Error teardown after fb_open succeeded (eFBState == FB_OPENED):
 *   1. Release initial locks (console_unlock, unlock_fb_info, drm_dev_exit)
 *   2. Call shared fb_release helper (re-enters DRM, takes locks, does fb_release)
 *   3. Unregister notifier if registered (synchronizes with running callbacks)
 *   4. Balance refs: put_device, kfree, module_put, drm_dev_put
 */
err_release_helper:
	console_unlock();
	unlock_fb_info(psLINFBInfo);
	drm_dev_exit(init_drm_idx);
	dc_sun4i_fb_release_once(gpsDeviceData);
	if(gpsDeviceData->bNotifierRegistered)
		bus_unregister_notifier(&platform_bus_type, &gpsDeviceData->sUnbindNotifier);
	put_device(&gpsDeviceData->psPlatformDev->dev);
	kfree(gpsDeviceData);
	module_put(psOwner);
	drm_dev_put(psDRMDev);
	return err;

/*
 * Error teardown after kzalloc but before fb_open (eFBState == FB_NONE):
 *   1. Release initial locks
 *   2. Balance refs: put_device, kfree, module_put, drm_dev_put
 *   No fb_release needed since fb_open never succeeded.
 */
err_release_data:
	console_unlock();
	unlock_fb_info(psLINFBInfo);
	drm_dev_exit(init_drm_idx);
	put_device(&gpsDeviceData->psPlatformDev->dev);
	kfree(gpsDeviceData);
	module_put(psOwner);
	drm_dev_put(psDRMDev);
	return err;

/*
 * Error teardown after successful try_module_get but before kzalloc:
 *   1. Release initial locks
 *   2. Balance refs: module_put, drm_dev_put
 *   No device data to free, no fb_open to unwind.
 */
err_module_put:
	console_unlock();
	unlock_fb_info(psLINFBInfo);
	drm_dev_exit(init_drm_idx);
	module_put(psOwner);
	drm_dev_put(psDRMDev);
	return err;

/*
 * Error teardown before try_module_get (no module reference owned):
 *   1. Release initial locks
 *   2. Balance refs: drm_dev_put
 *   psOwner is either NULL (validation errors) or set but not owned (failed get).
 *   NO module_put: we don't own a reference at this point.
 */
err_unlock:
	console_unlock();
	unlock_fb_info(psLINFBInfo);
	drm_dev_exit(init_drm_idx);
	drm_dev_put(psDRMDev);
err_out:
	return err;
}

static void __exit DC_SUN4I_exit(void)
{
	DC_SUN4I_DEVICE *psDeviceData = gpsDeviceData;
	struct drm_device *psDRMDev = psDeviceData->psDRMDev;
	struct module *psOwner = psDeviceData->psOwner; /* cached, no stale fb_info deref */

	/* Stop PVR callbacks first */
	DCUnregisterDevice(psDeviceData->hSrvHandle);

	/* Exactly-once fb_release via shared helper FIRST.
	 * This claims and performs the release while notifier coverage is still
	 * installed. If a concurrent unbind notifier fires, it serializes via
	 * sFBLock and sees the released state.
	 * Handles: drm_dev_enter protection, sFBLock serialization,
	 * lock_fb_info/console_lock ordering, and exactly-once claim.
	 * No sFBLock/fb_info/console locks held when this returns.
	 */
	dc_sun4i_fb_release_once(psDeviceData);

	/* Unregister notifier AFTER release is complete.
	 * bus_unregister_notifier synchronizes with any running callback.
	 * CRITICAL: must NOT be called while holding sFBLock, lock_fb_info,
	 * or console_lock. No locks held here (release helper returned).
	 */
	if(psDeviceData->bNotifierRegistered)
	{
		bus_unregister_notifier(&platform_bus_type, &psDeviceData->sUnbindNotifier);
		pr_info("dc_sun4i: unregistered platform-bus unbind notifier");
	}

	/* Balance all references */
	module_put(psOwner); /* balanced with try_module_get in init */

	put_device(&psDeviceData->psPlatformDev->dev); /* balanced with get_device in init */

	kfree(psDeviceData);

	/* Release the drm_device reference acquired in init */
	drm_dev_put(psDRMDev);
}

module_init(DC_SUN4I_init);
module_exit(DC_SUN4I_exit);

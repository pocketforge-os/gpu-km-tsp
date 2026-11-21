# dc_sun4i display controller module -- fbdev-to-PVR-DC bridge for sun4i-drm
# Builds as a separate kernel module (dc_sun4i.ko) that depends on pvrsrvkm.
# Imports 3 symbols: DCRegisterDevice, DCUnregisterDevice, DCDisplayConfigurationRetired.
#
# Design: fbdev seam (not KMS atomic). Binds registered_fb[0] populated by
# sun4i-drm's fbdev emulation (CONFIG_DRM_FBDEV_EMULATION=y, defaults to CONFIG_FB=y).
# Functionally equivalent to dc_sunxi but targets mainline sun4i-drm on Linux 7.2
# rather than legacy sunxi disp on 4.9 BSP. Bead tsp-71fdd65791d8498f4d78.

# DC_SUN4I_FORCE_XRGB8888: report the 32-bit display surface to the GPU stack as
# IMG_PIXFMT_B8G8R8X8_UNORM (90) instead of the default IMG_PIXFMT_B8G8R8A8_UNORM
# (89). The closed UM render-target classifier (libGLESv2 0x78fe8 "number of
# state/USC words" helper) recognizes 90 (B8G8R8X8) but NOT 89 (B8G8R8A8); an
# unrecognized format yields a render-target word-count of 0, which underflows
# ((0-1)>>5 = 0x07FFFFFF) into an OOB stack read and SIGSEGVs libusc during shader
# compile / makeCurrent. 90 is also semantically correct for a display scanout
# (alpha is meaningless) and selects libIMGegl's native 8888/32bpp config entry
# (table[90]), so no userspace blob patch is needed.
ccflags-y += -DDC_SUN4I_FORCE_XRGB8888

ccflags-y += \
 -I$(DDK_SRC)/services/3rdparty/dc_sun4i \
 -I$(DDK_SRC)/services/include \
 -I$(DDK_SRC)/include \
 -I$(DDK_SRC)/include/public

dc_sun4i-y += \
	services/3rdparty/dc_sun4i/dc_sun4i.o

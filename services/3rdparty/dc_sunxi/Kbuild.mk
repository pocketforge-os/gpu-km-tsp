# dc_sunxi display controller module -- fbdev-to-PVR-DC bridge
# Builds as a separate kernel module (dc_sunxi.ko) that depends on pvrsrvkm.
# Imports 3 symbols: DCRegisterDevice, DCUnregisterDevice, DCDisplayConfigurationRetired.

# DC_SUNXI_USE_SCREEN_BASE: the sunxi `disp` fbdev exposes the framebuffer as a
# vmalloc'd virtual address in screen_base; fix.smem_start is NOT the address the
# GPU needs. Without this define we hand the GPU smem_start+offset raw as a physical
# address -> bad-bus-transaction async SError (0xbf000000) in the post-Acquire present
# path. The vendor dc_sunxi.ko (BVNC 22.102.54.38) imports vmalloc_to_page +
# memstart_addr, proving it is built with this define (page_to_phys(vmalloc_to_page())
# path). Match it. (tsp-cv7.4.3)
ccflags-y += -DDC_SUNXI_USE_SCREEN_BASE

# DC_SUNXI_FORCE_XRGB8888: report the 32-bit display surface to the GPU stack as
# IMG_PIXFMT_B8G8R8X8_UNORM (90) instead of the default IMG_PIXFMT_B8G8R8A8_UNORM
# (89). The closed UM render-target classifier (libGLESv2 0x78fe8 "number of
# state/USC words" helper) recognizes 90 (B8G8R8X8) but NOT 89 (B8G8R8A8); an
# unrecognized format yields a render-target word-count of 0, which underflows
# ((0-1)>>5 = 0x07FFFFFF) into an OOB stack read and SIGSEGVs libusc during shader
# compile / makeCurrent. 90 is also semantically correct for a display scanout
# (alpha is meaningless) and selects libIMGegl's native 8888/32bpp config entry
# (table[90]), so no userspace blob patch is needed. Root-caused via core-dump +
# directed fast-loop patch 2026-06-21 (enum 89 proven unrecognized on-device;
# non-zero word-count proven to render 150 frames clean). (tsp-cv7.4.3)
ccflags-y += -DDC_SUNXI_FORCE_XRGB8888

ccflags-y += \
 -I$(DDK_SRC)/services/3rdparty/dc_sunxi \
 -I$(DDK_SRC)/services/include \
 -I$(DDK_SRC)/include \
 -I$(DDK_SRC)/include/public

dc_sunxi-y += \
	services/3rdparty/dc_sunxi/dc_sunxi.o

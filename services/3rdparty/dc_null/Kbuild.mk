# dc_null: minimal hardware-free "null" Display Class backend.
# Builds as a separate kernel module (dc_null.ko) that depends on pvrsrvkm.
# Imports 3 symbols: DCRegisterDevice, DCUnregisterDevice, DCDisplayConfigurationRetired.
#
# It registers ONE synthetic DC device with no scanout hardware so the closed
# vendor NULL_WSEGL usermode driver's WSEGL_InitialiseDisplay (which needs >=1
# DC device + a queryable panel/format/dim) can pass eglInitialize on the
# mainline (PVR_HEADLESS_NO_DC) build, where the fbdev-bound dc_sunxi cannot be
# built. Root cause + rationale: dc_null.c header comment; bead tsp-mc9m.11;
# tsp-mc9m.9 round-7 analysis; precedent commit 576a8ef (tsp-cv7.4.3).
#
# Unlike dc_sunxi this has NO CONFIG_FB / fbdev dependency and defines no
# board-specific flags: the pixel format (B8G8R8X8_UNORM 90, UM-recognised) and
# the synthetic panel dimensions are hardcoded in dc_null.c.

ccflags-y += \
 -I$(DDK_SRC)/services/3rdparty/dc_null \
 -I$(DDK_SRC)/services/include \
 -I$(DDK_SRC)/include \
 -I$(DDK_SRC)/include/public

dc_null-y += \
	services/3rdparty/dc_null/dc_null.o

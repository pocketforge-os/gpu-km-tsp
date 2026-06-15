# dc_sunxi display controller module -- fbdev-to-PVR-DC bridge
# Builds as a separate kernel module (dc_sunxi.ko) that depends on pvrsrvkm.
# Imports 3 symbols: DCRegisterDevice, DCUnregisterDevice, DCDisplayConfigurationRetired.

ccflags-y += \
 -I$(DDK_SRC)/services/3rdparty/dc_sunxi \
 -I$(DDK_SRC)/services/include \
 -I$(DDK_SRC)/include \
 -I$(DDK_SRC)/include/public

dc_sunxi-y += \
	services/3rdparty/dc_sunxi/dc_sunxi.o

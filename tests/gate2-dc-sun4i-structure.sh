#!/bin/bash
# Gate 2 (bead tsp-71fdd65791d8498f4d78): dc_sun4i module structure validation.
# Verifies that dc_sun4i has the correct DC API structure, exports, and build integration.
# This is a static analysis test that does not require a configured kernel tree.
# Usage: tests/gate2-dc-sun4i-structure.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL gate2 reason=$1 ${2:-}"; exit 1; }

# Check dc_sun4i.c exists
[ -f "$HERE/services/3rdparty/dc_sun4i/dc_sun4i.c" ] || fail dc_sun4i_c_missing

# Check Kbuild.mk exists
[ -f "$HERE/services/3rdparty/dc_sun4i/Kbuild.mk" ] || fail dc_sun4i_kbuild_mk_missing

# Check dc_sun4i.c has required DC API functions
DC_FILE="$HERE/services/3rdparty/dc_sun4i/dc_sun4i.c"
grep -q "DC_SUN4I_GetInfo" "$DC_FILE" || fail missing_GetInfo
grep -q "DC_SUN4I_PanelQueryCount" "$DC_FILE" || fail missing_PanelQueryCount
grep -q "DC_SUN4I_PanelQuery" "$DC_FILE" || fail missing_PanelQuery
grep -q "DC_SUN4I_FormatQuery" "$DC_FILE" || fail missing_FormatQuery
grep -q "DC_SUN4I_DimQuery" "$DC_FILE" || fail missing_DimQuery
grep -q "DC_SUN4I_ContextCreate" "$DC_FILE" || fail missing_ContextCreate
grep -q "DC_SUN4I_ContextDestroy" "$DC_FILE" || fail missing_ContextDestroy
grep -q "DC_SUN4I_ContextConfigure" "$DC_FILE" || fail missing_ContextConfigure
grep -q "DC_SUN4I_BufferAlloc" "$DC_FILE" || fail missing_BufferAlloc
grep -q "DC_SUN4I_BufferAcquire" "$DC_FILE" || fail missing_BufferAcquire
grep -q "DC_SUN4I_BufferRelease" "$DC_FILE" || fail missing_BufferRelease
grep -q "DC_SUN4I_BufferFree" "$DC_FILE" || fail missing_BufferFree

# Check DC_DEVICE_FUNCTIONS struct initialization
grep -q "DC_DEVICE_FUNCTIONS sDCFunctions" "$DC_FILE" || fail missing_DC_DEVICE_FUNCTIONS
grep -q "\.pfnGetInfo.*=.*DC_SUN4I_GetInfo" "$DC_FILE" || fail missing_pfnGetInfo_init
grep -q "\.pfnContextConfigure.*=.*DC_SUN4I_ContextConfigure" "$DC_FILE" || fail missing_pfnContextConfigure_init

# Check module init/exit
grep -q "module_init(DC_SUN4I_init)" "$DC_FILE" || fail missing_module_init
grep -q "module_exit(DC_SUN4I_exit)" "$DC_FILE" || fail missing_module_exit

# Check DCRegisterDevice call
grep -q "DCRegisterDevice(&sDCFunctions" "$DC_FILE" || fail missing_DCRegisterDevice

# Check DCDisplayConfigurationRetired call (flip completion)
grep -q "DCDisplayConfigurationRetired" "$DC_FILE" || fail missing_DCDisplayConfigurationRetired

# Check DRM-based fb_info discovery (Linux 7.2+ requirement)
grep -q "dc_sun4i_find_fb_info" "$DC_FILE" || fail missing_fb_info_discovery
grep -q "of_find_compatible_node" "$DC_FILE" || fail missing_of_find_compatible_node
grep -q "drm->fb_helper->info" "$DC_FILE" || fail missing_drm_fb_helper_access

# Check supported compatible strings (A10, A33, A100/A133)
grep -q "allwinner,sun4i-a10-display-engine" "$DC_FILE" || fail missing_a10_compatible
grep -q "allwinner,sun8i-a33-display-engine" "$DC_FILE" || fail missing_a33_compatible
grep -q "allwinner,sun50i-a100-display-engine" "$DC_FILE" || fail missing_a100_compatible

# Check reference balancing (put_device after of_find_device_by_node)
grep -q "put_device" "$DC_FILE" || fail missing_put_device_reference_balance

# Check DRM lifetime management (Linux 7.2 review requirements)
# drm_dev_get/put for drm_device reference pinning
grep -q "drm_dev_get" "$DC_FILE" || fail missing_drm_dev_get
grep -q "drm_dev_put" "$DC_FILE" || fail missing_drm_dev_put
# drm_dev_enter/exit for unplug synchronization
grep -q "drm_dev_enter" "$DC_FILE" || fail missing_drm_dev_enter
grep -q "drm_dev_exit" "$DC_FILE" || fail missing_drm_dev_exit
# psDRMDev stored in device context
grep -q "psDRMDev" "$DC_FILE" || fail missing_psDRMDev_field
# drm/drm_drv.h include for DRM API declarations
grep -q "include <drm/drm_drv.h>" "$DC_FILE" || fail missing_drm_drv_h_include
# PVRSRV_ERROR_DC_DEVICE_INACCESSIBLE for unplugged provider
grep -q "PVRSRV_ERROR_DC_DEVICE_INACCESSIBLE" "$DC_FILE" || fail missing_dc_device_inaccessible_error

# Verify drm_dev_enter is used in runtime fb_info accessors
# These functions access psLINFBInfo and must be protected against unplug
# For each accessor, find its line number and check ~80 lines after for drm_dev_enter
for func in DC_SUN4I_PanelQuery DC_SUN4I_DimQuery DC_SUN4I_ContextConfigureCheck DC_SUN4I_ContextConfigure DC_SUN4I_BufferAcquire; do
	line=$(grep -n "${func}(IMG_HANDLE" "$DC_FILE" | grep -v "\.pfn\|sDCFunctions" | head -1 | cut -d: -f1)
	if [ -z "$line" ]; then
		fail func_not_found "$func"
	fi
	end=$((line + 80))
	if ! sed -n "${line},${end}p" "$DC_FILE" | grep -q "drm_dev_enter"; then
		fail missing_drm_dev_enter_in "$func"
	fi
done

# --- LIFECYCLE AND ERROR-PATH TESTS ---

# Verify error unwind labels exist in init
if ! grep -q "err_drm_put:" "$DC_FILE"; then
	fail missing_err_drm_put_label
fi
if ! grep -q "err_drm_exit:" "$DC_FILE"; then
	fail missing_err_drm_exit_label
fi
if ! grep -q "err_unlock:" "$DC_FILE"; then
	fail missing_err_unlock_label
fi

# Verify teardown ordering in init: err_unlock must come BEFORE err_drm_exit
# which must come BEFORE err_drm_put (fall-through label order)
unlock_line=$(grep -n "^err_unlock:" "$DC_FILE" | head -1 | cut -d: -f1)
drm_exit_line=$(grep -n "^err_drm_exit:" "$DC_FILE" | head -1 | cut -d: -f1)
drm_put_line=$(grep -n "^err_drm_put:" "$DC_FILE" | head -1 | cut -d: -f1)
if [ -n "$unlock_line" ] && [ -n "$drm_exit_line" ] && [ -n "$drm_put_line" ]; then
	if [ "$unlock_line" -ge "$drm_exit_line" ] || [ "$drm_exit_line" -ge "$drm_put_line" ]; then
		fail teardown_order_wrong "err_unlock=$unlock_line err_drm_exit=$drm_exit_line err_drm_put=$drm_put_line (expected unlock<exit<put)"
	fi
else
	fail teardown_labels_missing "unlock=$unlock_line exit=$drm_exit_line put=$drm_put_line"
fi

# Verify validation errors in init go to err_unlock (not err_drm_put which skips lock release)
# Check that at least one validation error uses "goto err_unlock"
if ! grep -q "goto err_unlock" "$DC_FILE"; then
	fail validation_errors_wrong_target "no goto err_unlock found; validation errors must release locks"
fi

# Verify psOwner field exists in device struct (cached module reference)
if ! grep -q "struct module.*psOwner" "$DC_FILE"; then
	fail missing_psOwner_field "device struct must cache fbops->owner independently"
fi

# Verify psOwner is set before DCRegisterDevice publication
reg_line=$(grep -n "if(DCRegisterDevice" "$DC_FILE" | head -1 | cut -d: -f1)
owner_assign_line=$(grep -n "gpsDeviceData->psOwner = " "$DC_FILE" | head -1 | cut -d: -f1)
if [ -n "$reg_line" ] && [ -n "$owner_assign_line" ]; then
	if [ "$owner_assign_line" -ge "$reg_line" ]; then
		fail owner_set_after_publication "psOwner=$owner_assign_line DCRegisterDevice=$reg_line (must set before)"
	fi
else
	fail owner_cache_missing "psOwner assignment or DCRegisterDevice not found"
fi

# Verify DC_SUN4I_exit uses cached psOwner (not stale fb_info->fbops->owner)
exit_block=$(awk '/^static void __exit DC_SUN4I_exit/,/^\}/' "$DC_FILE")
if ! echo "$exit_block" | grep -q "psOwner"; then
	fail exit_uses_stale_fb_info "DC_SUN4I_exit must use cached psOwner, not fb_info->fbops->owner"
fi
# Exit must NOT dereference fbops->owner directly
if echo "$exit_block" | grep -q "fbops->owner"; then
	fail exit_dereferences_stale_fbops "DC_SUN4I_exit must not dereference fbops->owner"
fi

# Verify DC_SUN4I_exit calls drm_dev_put
if ! echo "$exit_block" | grep -q "drm_dev_put"; then
	fail missing_drm_dev_put_in_exit
fi

# Verify DC_SUN4I_exit calls module_put (balanced with try_module_get)
if ! echo "$exit_block" | grep -q "module_put"; then
	fail missing_module_put_in_exit
fi

# Verify DC_SUN4I_exit calls DCUnregisterDevice before teardown
unreg_line=$(echo "$exit_block" | grep -n "DCUnregisterDevice" | head -1 | cut -d: -f1)
put_line=$(echo "$exit_block" | grep -n "drm_dev_put" | head -1 | cut -d: -f1)
if [ -n "$unreg_line" ] && [ -n "$put_line" ]; then
	if [ "$unreg_line" -ge "$put_line" ]; then
		fail exit_unregister_order "DCUnregisterDevice=$unreg_line drm_dev_put=$put_line (unregister first)"
	fi
fi

# Verify drm_dev_enter is used in dc_sun4i_find_fb_info (discovery protection)
discovery_line=$(grep -n "^static int dc_sun4i_find_fb_info" "$DC_FILE" | head -1 | cut -d: -f1)
if [ -n "$discovery_line" ]; then
	discovery_end=$((discovery_line + 80))
	if ! sed -n "${discovery_line},${discovery_end}p" "$DC_FILE" | grep -q "drm_dev_enter"; then
		fail missing_drm_dev_enter_in_discovery "fb_helper dereference must be protected"
	fi
fi

# Check CONFIG_DRM_FBDEV_EMULATION guard
grep -q "#if !defined(CONFIG_DRM_FBDEV_EMULATION)" "$DC_FILE" || fail missing_CONFIG_DRM_FBDEV_EMULATION_guard

# Check Kbuild.mk has required defines
KBUILD_FILE="$HERE/services/3rdparty/dc_sun4i/Kbuild.mk"
grep -q "DC_SUN4I_FORCE_XRGB8888" "$KBUILD_FILE" || fail missing_DC_SUN4I_FORCE_XRGB8888
grep -q "dc_sun4i-y" "$KBUILD_FILE" || fail missing_dc_sun4i-y

# Check Makefile integration
MAKEFILE="$HERE/Makefile"
grep -q "PVR_DC_SUN4I" "$MAKEFILE" || fail missing_PVR_DC_SUN4I_in_Makefile
grep -q "services/3rdparty/dc_sun4i/Kbuild.mk" "$MAKEFILE" || fail missing_dc_sun4i_Kbuild_include
grep -q "dc_sun4i.o" "$MAKEFILE" || fail missing_dc_sun4i.o_in_Makefile

# Check build script integration
BUILD_SCRIPT="$HERE/build-sunxi-a133.sh"
grep -q "PVR_DC_SUN4I" "$BUILD_SCRIPT" || fail missing_PVR_DC_SUN4I_in_build_script
grep -q "dc_sun4i.ko" "$BUILD_SCRIPT" || fail missing_dc_sun4i.ko_in_build_script

echo "PASS gate2 dc_sun4i structure validated"
echo "  dc_sun4i.c: $(wc -l < "$DC_FILE") lines"
echo "  Kbuild.mk: $(wc -l < "$KBUILD_FILE") lines"
echo "  DC API functions: 12/12 present"
echo "  Lifecycle: teardown ordering (unlock<exit<put), psOwner cached, discovery protected"
echo "  Build integration: Makefile + build-sunxi-a133.sh"

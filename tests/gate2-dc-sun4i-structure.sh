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

# --- SUCCESS-PATH CONTROL-FLOW TESTS ---
# Critical: the success path must NOT fall through to err_drm_put.
# The drm_dev reference must be retained in gpsDeviceData until DC_SUN4I_exit.

# Extract the init function
init_block=$(awk '/^static int __init DC_SUN4I_init/,/^}/' "$DC_FILE")

# Test 1: Verify success path ends with direct return 0, not goto
# Look for the pattern: console_unlock(); unlock_fb_info(); drm_dev_exit(); return 0;
# This sequence should appear BEFORE any error labels
success_return_line=$(echo "$init_block" | grep -n "return 0;" | head -1 | cut -d: -f1)
if [ -z "$success_return_line" ]; then
	fail missing_success_return_0 "init must have direct 'return 0;' for success path"
fi

# Test 2: Verify err_drm_put label exists and is AFTER the success return
err_drm_put_label_line=$(echo "$init_block" | grep -n "^err_drm_put:" | head -1 | cut -d: -f1)
if [ -z "$err_drm_put_label_line" ]; then
	fail missing_err_drm_put_label "err_drm_put label must exist for error paths"
fi
if [ "$success_return_line" -ge "$err_drm_put_label_line" ]; then
	fail success_path_reaches_drm_put "return 0 at line $success_return_line must come BEFORE err_drm_put at line $err_drm_put_label_line"
fi

# Test 3: Verify the success path does NOT contain "goto err_drm_put" or "goto err_drm_exit"
# Extract lines between "Found usable fbdev" (success path start) and "return 0;"
success_path=$(echo "$init_block" | sed -n '/Found usable fbdev/,/return 0;/p')
if echo "$success_path" | grep -q "goto err_drm_put\|goto err_drm_exit"; then
	fail success_path_has_goto_drm "success path must not goto err_drm_put or err_drm_exit (must retain drm_dev ref)"
fi

# Test 4: Verify success path contains console_unlock, unlock_fb_info, drm_dev_exit (but NOT drm_dev_put)
if ! echo "$success_path" | grep -q "console_unlock()"; then
	fail success_path_missing_console_unlock "success path must release console lock"
fi
if ! echo "$success_path" | grep -q "unlock_fb_info("; then
	fail success_path_missing_unlock_fb_info "success path must release fb_info lock"
fi
if ! echo "$success_path" | grep -q "drm_dev_exit("; then
	fail success_path_missing_drm_dev_exit "success path must leave drm_dev_enter section"
fi
if echo "$success_path" | grep -q "drm_dev_put("; then
	fail success_path_has_drm_dev_put "success path MUST NOT call drm_dev_put (reference retained for exit)"
fi

# Test 5: Negative mutation test - verify no code path after success can reach err_drm_put via fall-through
# The success path ends with "return 0;" which exits the function, so no fall-through is possible
# Error labels can appear between return 0; and the actual cleanup code, but there should be no
# executable code that could run after return 0; before hitting a goto or the first error label
# Use awk to extract lines after "return 0;" and before the first error label (err_unregister_notifier: or err_put_device:)
between=$(echo "$init_block" | awk '/return 0;/{found=1; next} /^err_/{exit} found{print}')
# Strip out multi-line comments, single-line comments, empty lines
stripped=$(echo "$between" | sed '/\/\*/,/\*\//d' | sed '/^[[:space:]]*\/\//d' | sed '/^[[:space:]]*$/d' | sed '/^[[:space:]]*\*/d')
if [ -n "$stripped" ]; then
	fail success_path_has_fallthrough_code "unexpected code between 'return 0;' and error labels: $stripped"
fi

# Test 6: Verify error paths use correct goto targets
# Validation errors should goto err_unlock (releases locks then falls through to drm_exit/drm_put)
# DCRegisterDevice failure should goto err_put_device (releases device ref, then falls through to kfree)
if ! echo "$init_block" | grep -q "goto err_put_device"; then
	fail missing_goto_err_put_device "DCRegisterDevice failure must goto err_put_device"
fi
if ! echo "$init_block" | grep -q "goto err_unlock"; then
	fail missing_goto_err_unlock "validation errors must goto err_unlock"
fi

# Test 7: Verify err_unlock falls through to err_drm_exit which falls through to err_drm_put
# This ensures error paths correctly release ALL resources
unlock_to_exit=$(echo "$init_block" | sed -n '/^err_unlock:/,/^err_drm_exit:/p')
exit_to_put=$(echo "$init_block" | sed -n '/^err_drm_exit:/,/^err_drm_put:/p')
put_to_out=$(echo "$init_block" | sed -n '/^err_drm_put:/,/^err_out:/p')
if ! echo "$unlock_to_exit" | grep -q "console_unlock"; then
	fail err_unlock_missing_console_unlock "err_unlock must release console lock"
fi
if ! echo "$unlock_to_exit" | grep -q "unlock_fb_info"; then
	fail err_unlock_missing_unlock_fb_info "err_unlock must release fb_info lock"
fi
if ! echo "$exit_to_put" | grep -q "drm_dev_exit"; then
	fail err_drm_exit_missing_drm_dev_exit "err_drm_exit must call drm_dev_exit"
fi
if ! echo "$put_to_out" | grep -q "drm_dev_put"; then
	fail err_drm_put_missing_drm_dev_put "err_drm_put must call drm_dev_put"
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

# Test 8: fb_release notifier lifecycle - structural verification
# Provider unbind notifier ensures fb_release runs before sun4i-drm teardown

# 8a: Notifier callback function exists
grep -q "dc_sun4i_unbind_notifier" "$DC_FILE" || fail missing_unbind_notifier_function

# 8b: Notifier fields in DC_SUN4I_DEVICE struct
grep -q "struct notifier_block.*sUnbindNotifier" "$DC_FILE" || fail missing_notifier_block_field
grep -q "struct platform_device.*psPlatformDev" "$DC_FILE" || fail missing_platform_dev_field
grep -q "struct mutex.*sFBLock" "$DC_FILE" || fail missing_fb_lock_field
grep -q "bool.*bFBOpened" "$DC_FILE" || fail missing_fb_opened_flag
grep -q "bool.*bFBReleased" "$DC_FILE" || fail missing_fb_released_flag
grep -q "bool.*bNotifierRegistered" "$DC_FILE" || fail missing_notifier_registered_flag

# 8c: Notifier registered in init after DCRegisterDevice
grep -q "bus_register_notifier.*platform_bus_type" "$DC_FILE" || fail missing_bus_register_notifier

# 8d: Notifier unregistered in exit (synchronizes with running callback)
grep -q "bus_unregister_notifier.*platform_bus_type" "$DC_FILE" || fail missing_bus_unregister_notifier

# 8e: Exactly-once release logic - check bFBReleased is tested before calling fb_release
exit_block=$(sed -n '/^static void __exit DC_SUN4I_exit/,/^}/p' "$DC_FILE")
if ! echo "$exit_block" | grep -q "fb_release_needed"; then
	fail missing_fb_release_needed_check "exit must check if fb_release already done"
fi
if ! echo "$exit_block" | grep -q "bFBReleased = true"; then
	fail missing_fb_released_set "exit must set bFBReleased after calling fb_release"
fi

# 8f: Mutex initialization and usage
grep -q "mutex_init.*sFBLock" "$DC_FILE" || fail missing_mutex_init
if ! echo "$exit_block" | grep -q "mutex_lock.*sFBLock"; then
	fail missing_mutex_lock_in_exit "exit must use mutex for serialization"
fi

# 8g: Platform device reference balance
grep -q "get_device.*psPlatformDev" "$DC_FILE" || fail missing_get_device
grep -q "put_device.*psPlatformDev" "$DC_FILE" || fail missing_put_device

# 8h: Notifier callback matches exact platform device
notifier_block=$(sed -n '/^static int dc_sun4i_unbind_notifier/,/^}/p' "$DC_FILE")
if ! echo "$notifier_block" | grep -q "dev != &psDeviceData->psPlatformDev->dev"; then
	fail notifier_missing_device_match "notifier must match exact platform device"
fi

# 8i: Notifier handles BUS_NOTIFY_UNBIND_DRIVER action
if ! echo "$notifier_block" | grep -q "BUS_NOTIFY_UNBIND_DRIVER"; then
	fail notifier_missing_unbind_action "notifier must handle BUS_NOTIFY_UNBIND_DRIVER"
fi

# 8j: Notifier callback uses lock_fb_info/console_lock (same contract as exit path)
if ! echo "$notifier_block" | grep -q "lock_fb_info"; then
	fail notifier_missing_lock_fb_info "notifier callback must call lock_fb_info before fb_release"
fi
if ! echo "$notifier_block" | grep -q "console_lock"; then
	fail notifier_missing_console_lock "notifier callback must call console_lock before fb_release"
fi
if ! echo "$notifier_block" | grep -q "console_unlock"; then
	fail notifier_missing_console_unlock "notifier callback must call console_unlock after fb_release"
fi
if ! echo "$notifier_block" | grep -q "unlock_fb_info"; then
	fail notifier_missing_unlock_fb_info "notifier callback must call unlock_fb_info after fb_release"
fi

# 8k: Notifier registered BEFORE DCRegisterDevice publication
# Critical: if notifier registration fails or is done after publication, provider unbind can be missed
init_block=$(sed -n '/^static int __init DC_SUN4I_init/,/^}/p' "$DC_FILE")
notifier_reg_line=$(echo "$init_block" | grep -n "bus_register_notifier" | head -1 | cut -d: -f1)
dc_register_line=$(echo "$init_block" | grep -n "if(DCRegisterDevice" | head -1 | cut -d: -f1)
if [ -z "$notifier_reg_line" ] || [ -z "$dc_register_line" ]; then
	fail notifier_or_dc_register_not_found "notifier_reg=$notifier_reg_line dc_register=$dc_register_line"
fi
if [ "$notifier_reg_line" -ge "$dc_register_line" ]; then
	fail notifier_registered_after_publication "bus_register_notifier at line $notifier_reg_line must be BEFORE DCRegisterDevice at line $dc_register_line"
fi

# 8l: Notifier registration failure must fail init (not just log warning)
# If bus_register_notifier fails, init must goto error path (not continue)
# Look for the pattern: if(bus_register_notifier(...) != 0) goto err_...
notifier_fail_block=$(echo "$init_block" | sed -n '/bus_register_notifier/,/^[[:space:]]*}$/p' | head -20)
if echo "$notifier_fail_block" | grep -q "goto err_"; then
	: # Good - notifier failure causes init to fail
else
	fail notifier_failure_not_fatal "bus_register_notifier failure must cause init to fail (goto err_...)"
fi

# 8m: Verify err_unregister_notifier label exists for cleanup
if ! grep -q "err_unregister_notifier:" "$DC_FILE"; then
	fail missing_err_unregister_notifier_label "err_unregister_notifier label required for notifier cleanup"
fi

# 8n: Verify err_unregister_notifier comes before err_put_device (fall-through order)
unreg_notifier_line=$(grep -n "^err_unregister_notifier:" "$DC_FILE" | head -1 | cut -d: -f1)
err_put_device_line=$(grep -n "^err_put_device:" "$DC_FILE" | head -1 | cut -d: -f1)
if [ -n "$unreg_notifier_line" ] && [ -n "$err_put_device_line" ]; then
	if [ "$unreg_notifier_line" -ge "$err_put_device_line" ]; then
		fail err_unregister_notifier_order_wrong "err_unregister_notifier=$unreg_notifier_line must be BEFORE err_put_device=$err_put_device_line"
	fi
else
	fail err_unregister_notifier_labels_missing "unreg_notifier=$unreg_notifier_line put_device=$err_put_device_line"
fi

echo "PASS gate2 dc_sun4i structure validated"
echo "  dc_sun4i.c: $(wc -l < "$DC_FILE") lines"
echo "  Kbuild.mk: $(wc -l < "$KBUILD_FILE") lines"
echo "  DC API functions: 12/12 present"
echo "  Lifecycle: teardown ordering, psOwner cached, discovery protected, success path verified"
echo "  fb_release notifier: registered BEFORE publication, fails closed, uses fb/console locks"
echo "  Build integration: Makefile + build-sunxi-a133.sh"

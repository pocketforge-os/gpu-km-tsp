# Design: dc_sun4i Display Class Backend for Linux 7.2

## Executive Summary

Design an owned PVR Display Class backend (`dc_sun4i`) for Linux 7.2 that presents through sun4i-drm using DRM fbdev emulation. This is a source-forked replacement for the vendor blob's display backend, maintaining compatibility with the closed user-mode DDK.

## Design Decision: DRM fbdev emulation (chosen)

### Analysis of Viable Seams

**Option 1: DRM fbdev emulation (CHOSEN)**
- Reuses the proven `dc_sunxi` pattern (binds `registered_fb[0]`)
- Requires `CONFIG_FB=y` and `CONFIG_DRM_FBDEV_EMULATION=y`
- sun4i-drm populates `registered_fb[]` when `DRM_FBDEV_DMA_DRIVER_OPS` is active
- Simpler implementation, lower risk, proven to work with PVR DDK
- Aligns with existing deployment: build script checks CONFIG_FB and falls back to dc_null if absent

**Option 2: KMS atomic API (rejected for stage 1)**
- Modern, works without CONFIG_FB
- Requires implementing full DRM/KMS client in kernel space
- Significantly more complex: mode setting, plane management, atomic commits, fence handling
- Higher risk, longer implementation time
- May be considered for stage 2 if CONFIG_FB support is deprecated

### Evidence from Source

1. **sun4i-drm supports fbdev emulation**:
   - `drivers/gpu/drm/sun4i/sun4i_drv.c:58`: Uses `DRM_FBDEV_DMA_DRIVER_OPS`
   - `include/drm/drm_fbdev_dma.h:12-18`: Expands to `.fbdev_probe = drm_fbdev_dma_driver_fbdev_probe` when `CONFIG_DRM_FBDEV_EMULATION=y`

2. **CONFIG_DRM_FBDEV_EMULATION defaults to FB**:
   - `drivers/gpu/drm/clients/Kconfig:27`: `default FB`
   - If `CONFIG_FB=y`, then `CONFIG_DRM_FBDEV_EMULATION=y` by default

3. **sunxi_defconfig enables DRM and sun4i-drm**:
   - `arch/arm/configs/sunxi_defconfig`: `CONFIG_DRM=y`, `CONFIG_DRM_SUN4I=y`
   - CONFIG_FB not explicitly set, but if enabled in deployment, fbdev emulation works

4. **Existing dc_sunxi proves the pattern**:
   - Binds `registered_fb[0]` successfully
   - Implements full DC API with flip via yoffset panning
   - Proven to work with closed UM DDK

### Chosen Seam: DRM fbdev emulation

**Rationale**:
- Lowest risk: reuses proven dc_sunxi pattern
- Minimal code: adapt dc_sunxi to sun4i-drm specifics
- Build system already handles CONFIG_FB check
- Aligns with current deployment model (fbdev-based)

**Constraint**: Requires `CONFIG_FB=y` in kernel config. If absent, fall back to `dc_null` (headless).

## Architecture

### Module Structure

```
services/3rdparty/dc_sun4i/
├── Kbuild.mk          # Build definitions
├── dc_sun4i.c         # Main backend implementation
├── dc_sun4i.h         # Internal header
└── Makefile           # Standalone build (optional)
```

### Key Components

1. **Device Registration**
   - Bind to `registered_fb[0]` (populated by sun4i-drm fbdev emulation)
   - Validate framebuffer parameters (resolution, format, stride)
   - Register with `DCRegisterDevice()`

2. **Panel Query**
   - Report single panel matching fbdev geometry
   - Format: `DC_FORMAT_B8G8R8X8_UNORM` (90) or `DC_FORMAT_B8G8R8A8_UNORM` (89)
   - Dimensions: from `fb_info->var.xres/yres`

3. **Buffer Management**
   - Allocate: `kmalloc` or `vmalloc` for shadow buffer (if needed)
   - Acquire: Map fbdev video memory, return CPU address + DMA address
   - Release: Unmap
   - Free: Cleanup

4. **Page Flip**
   - Use `fb_pan_display()` to flip via yoffset panning
   - Double-buffering: two pages in fbdev video memory
   - Completion: Call `DCDisplayConfigurationRetired()` after flip

5. **Cleanup**
   - Unregister device: `DCUnregisterDevice()`
   - Release fbdev resources

### Integration Points

- **Build System**: Add to `Makefile` (like dc_sunxi), controlled by `PVR_HEADLESS_NO_DC!=1` and `CONFIG_FB` check
- **Module Dependency**: Depends on `pvrsrvkm.ko` (provides DC API)
- **Runtime Dependency**: Requires sun4i-drm loaded and fbdev emulation active

## Implementation Plan

### Stage 1: Core Backend (this work order)

1. **Create dc_sun4i module skeleton**
   - Copy structure from dc_sunxi
   - Adapt for sun4i-drm specifics

2. **Implement DC API callbacks**
   - GetInfo, PanelQueryCount, PanelQuery, FormatQuery, DimQuery
   - ContextCreate, ContextConfigure, ContextDestroy
   - BufferAlloc, BufferAcquire, BufferRelease, BufferFree

3. **Implement flip logic**
   - Double-buffer via yoffset panning
   - Flip completion notification

4. **Build integration**
   - Add to Makefile, Kbuild.mk
   - Config checks for CONFIG_FB

5. **Tests**
   - Unit tests with fake fbdev environment
   - Build test against kernel-sunxi-7.x
   - Integration test: module load, DC device registration

### Stage 2 (future, not in scope)

- KMS atomic backend (if CONFIG_FB deprecated)
- Hardware validation on TSP device

## Test Strategy

### Unit Tests (with fake/mock environment)

1. **Fake fbdev fixture**: Create a fake `registered_fb[0]` with known parameters
2. **Test registration**: Verify `DCRegisterDevice()` succeeds
3. **Test panel query**: Verify format/dimensions match fbdev
4. **Test buffer lifecycle**: Alloc → Acquire → Release → Free
5. **Test flip**: Verify yoffset panning and completion callback
6. **Test cleanup**: Verify `DCUnregisterDevice()` succeeds

### Build Tests

1. **Build against kernel-sunxi-7.x**: Verify module compiles
2. **Build with CONFIG_FB=y**: Verify dc_sun4i.ko is built
3. **Build with CONFIG_FB=n**: Verify fallback to dc_null

### Integration Tests

1. **Module load**: `insmod dc_sun4i.ko` succeeds
2. **DC device visible**: Verify device appears in PVR services
3. **EGL init**: Closed UM blob's `eglInitialize` succeeds (requires device validation on hardware)

## Risk Mitigation

1. **CONFIG_FB not enabled**: Build script already detects and falls back to dc_null
2. **registered_fb[0] not populated**: Module init fails gracefully, logs error
3. **Format mismatch**: Validate fbdev format, reject if unsupported
4. **Flip failure**: Log error, continue with single-buffered mode

## Compliance

- **Owned source**: All code is source-forked, no vendor blobs
- **DC API compliance**: Implements all mandatory DC_DEVICE_FUNCTIONS callbacks
- **Kernel compatibility**: Linux 7.2, sun4i-drm with fbdev emulation
- **BVNC alignment**: No BVNC dependency (display backend is BM side)

## Deliverables

1. `services/3rdparty/dc_sun4i/dc_sun4i.c` - Backend implementation
2. `services/3rdparty/dc_sun4i/Kbuild.mk` - Build definitions
3. `Makefile` - Integration with main build
4. `tests/dc_sun4i/` - Unit tests with fake fbdev
5. Documentation: This design doc + README

## Success Criteria

- [ ] dc_sun4i.ko builds against kernel-sunxi-7.x
- [ ] Unit tests pass with fake fbdev environment
- [ ] Module loads and registers DC device (on hardware with CONFIG_FB=y)
- [ ] Falls back to dc_null when CONFIG_FB=n
- [ ] No regression in existing dc_sunxi or dc_null paths

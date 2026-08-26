# GE8300 SIPF-v1 region-header write-count analysis

## Result

There is no separately programmable "number of region headers to write" field in
the Rogue HWRT interface in DDK 1.19.6345021.  The producer's spatial extent is
`RGX_CR_TE_SCREEN` (`XMAX`, `YMAX`, inclusive); on this generation its units are
**32-pixel TE tiles**.  The public register definition says exactly that at
`kernel-sunxi-6.x:drivers/gpu/drm/imagination/pvr_rogue_cr_defs_client.h:101-118`.
`TE_MTILE1/2` describe macrotile boundaries, `TE_MTILE_STRIDE` describes the
macrotile-array stride, and `rgn_header_size` describes backing-store capacity;
none is a second region-record loop count.

Consequently, a 640x480 GE8300 geometry pass has a TE extent of 20x15 and writes
300 consecutive five-byte SIPF-v1 records.  The observed 300 is not a
driver-selected 16px-versus-32px array length that can be changed to 1200.  It is
the hardware consequence of the GE8300 TE's 32-pixel tile address space.  The
open path is wrong because it allocates and later interprets the same array as
40x30 16-pixel records.  The actionable fix is to make the open **consumer/layout**
use the 20x15 producer grid (or add an explicit 20x15-to-40x30 expansion before
the ISP); there is no evidence-backed open-side change that makes this TE emit
1200 native records.

This also corrects an important premise in the work order: there is no valid
measurement that the closed path writes 1200 five-byte records.  The supposed
closed `odyssey-rgn` capture was subsequently shown (RE-44 r517) to contain ASCII
symbol/error strings, not region-header records.  The closed driver proves that
full-frame rendering is possible, but not that it uses a 1200-record producer
array.

## DDK path: values are transported, not recomputed

The userspace bridge ABI supplies four distinct quantities:

* `ui32TEScreen`, `ui32TEMTILE1`, `ui32TEMTILE2`, and `ui32MTileStride` are
  independent inputs in
  `generated/rogue/rgxta3d_bridge/common_rgxta3d_bridge.h:99-106`.
* The generated bridge passes all four unchanged into `RGXCreateHWRTDataSet()` at
  `generated/rogue/rgxta3d_bridge/server_rgxta3d_bridge.c:365-392`.
* The KM entry point receives them independently at
  `services/server/devices/rogue/rgxta3d.c:1928-1954` and copies them without a
  count calculation into firmware-visible `RGXFWIF_HWRTDATA_COMMON` at
  `services/server/devices/rogue/rgxta3d.c:1998-2016`.
* The firmware ABI defines `ui32TEScreen`, `ui32MTileStride`, and
  `uiRgnHeaderSize` as separate members at
  `include/rogue/rgx_fwif_km.h:2415-2437`.  It provides no `numRegions` or
  region-array-length member.

Thus `rgxta3d.c` cannot be the source of a hidden 300-record clamp: it neither
derives nor rewrites an extent.  It only publishes the userspace register image
and buffer capacity to firmware.  Firmware source is not present in this KM
repository, so the final register write cannot be line-pinned here; the ABI and
the live register capture establish that firmware consumes these values.

For comparison, Mesa's Services winsys constructs `CR_TE_SCREEN` directly from
`x_tile_max/y_tile_max` at
`gpu-um-tsp:src/imagination/vulkan/winsys/pvrsrvkm/pvr_arch_srv_job_render.c:294-299`
and passes it through the bridge at the same file's lines 368-396.  Mesa's
generic SIPF-v1 calculation currently derives those maxima from its advertised
16px feature tile: `num_tiles=ceil(size/tile_size)`, rounded to two, at
`gpu-um-tsp:src/imagination/vulkan/pvr_arch_job_render.c:123-143`.  For 640x480
that yields 39 and 29.  This is the 16px logical/ISP layout, not proof that the
GE8300 TE has 16px producer tiles.

## Open DRM path and the mismatch

The open kernel has made the two domains explicit:

* `tiles_x/y` are computed on a 16px grid at
  `kernel-sunxi-6.x:drivers/gpu/drm/imagination/pvr_hwrt_geom.c:83-86`.
* For 1x sampling, `hw_tiles_x/y` are separately computed on a 32px grid at the
  same file's lines 98-104.
* The region allocation count remains the 16px product at lines 88-95 and
  151-156, hence 40x30 = 1200 records at 640x480.
* The TE boundary is deliberately packed from the 32px `hw_tiles` at lines
  135-148, hence XMAX=19/YMAX=14 and a 20x15 producer extent.
* `pvr_hwrt.c` installs those 32px TE values at
  `kernel-sunxi-6.x:drivers/gpu/drm/imagination/pvr_hwrt.c:439-458` and
  `:543-548`, while retaining the 16px region dimensions and allocation at
  `:499-502` and `:558-559`.

This is the exact producer/consumer disagreement:

| Quantity | Current unit | 640x480 value |
| --- | --- | ---: |
| TE producer extent (`TE_SCREEN`) | 32px hardware tile | 20x15 = 300 |
| Region allocation/ISP indexing | 16px logical tile | 40x30 = 1200 |

The register documentation also distinguishes `PPP_SCREEN` (pixel extent) from
`TE_SCREEN` (tile extent) at
`kernel-sunxi-6.x:drivers/gpu/drm/imagination/pvr_rogue_cr_defs_client.h:120-137`.
Mesa `TA_STATE_TERMINATE0.clip_right/clip_bottom` is another downstream/control-
stream clip and is not this HWRT TE extent, consistent with RE-44 r521.

## What can and cannot be changed

Changing `TE_SCREEN` from 19/14 to 39/29 is the obvious source-level experiment:
remove the assignments of `register_tiles_x/y = geom->hw_tiles_x/y` at
`kernel-sunxi-6.x:drivers/gpu/drm/imagination/pvr_hwrt_geom.c:101-102`, leaving
the initial 16px `tiles_x/y` values from lines 83-86.  That changes
`packed_tile_max` from `19 | (14 << 12)` to `39 | (29 << 12)`.

It is **not** an acceptable claimed fix.  The campaign already ran that negative
control (ledger r496/R142-R143): live `te_screen=39,29`,
`mtile_stride=1200`, and a 1200-record allocation still produced 300 records and
25% coverage.  RE-44 r521 additionally set the terminate clip to 39/29 and again
left the count at 300.  Kernel `mtile_stride`, region count/stride, and terminate
clip are therefore independently ruled out.  Claiming the two-line
`TE_SCREEN` edit would make the TA write 1200 would contradict direct hardware
evidence.

The exact evidence-backed open-side correction is instead at the 16px region
layout computation in
`kernel-sunxi-6.x:drivers/gpu/drm/imagination/pvr_hwrt_geom.c:83-95`:

* **current:** `regions_x = ceil(width/16)` and
  `regions_y = ceil(height/16)` (40x30, 1200 native records);
* **required producer-coherent layout:** `regions_x = ceil(width/32)` and
  `regions_y = ceil(height/32)` (20x15, 300 native records), with all matching
  allocation-size and ISP region-indexing consumers changed together; or retain
  40x30 only if a new explicit expansion maps each 32px producer record to its
  four 16px consumer records.

That correction needs its own implementation/design bead because merely shrinking
the allocation is unsafe and earlier isolated region-count experiments did not
change coverage.  Every consumer of the layout must move coherently.  The present
analysis intentionally changes no rendering behavior.

## Evidence strength and falsifier

The positive source evidence is: a documented 32px `TE_SCREEN`, no independent
record-count field in the DDK firmware ABI, an exact 20x15 observed write count,
and invariance under every exposed candidate field.  Together these support a
hardware-defined producer count, not an undiscovered host count register.

This conclusion would be falsified by either (a) a firmware implementation that
shows another count field controlling the TE region-header loop, or (b) a valid
post-geometry read-back from the closed GE8300 path showing 1200 native five-byte
records for 640x480.  Neither artifact is currently available; the earlier
closed capture is not such evidence.

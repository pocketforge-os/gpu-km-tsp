# GE8300 quarter-frame fragment-walker analysis

## Scope and conclusion

This is a source-only trace of the Rogue (GE8300) KM path. It assumes the
observed premises in `tsp-mc9m.41.654`: both render targets contain 3,600
full-frame region headers, TA finishes, and `PROCESS_EMPTY_TILES` is enabled.
No device result is inferred here.

The KM has no separate width/height argument in the KCCB 3D kick. The fragment
extent reaches firmware through **two FW-visible objects**:

1. the complete, UM-built `RGXFWIF_CMD3D` byte blob in the 3D client CCB; and
2. the `RGXFWIF_HWRTDATA` selected by that command, whose
   `sHWRTDataCommonFwAddr` names the render-target-dimension-dependent
   `RGXFWIF_HWRTDATA_COMMON`.

The most important correction to the working model is that `s3DCmdKickData`
does **not** contain `RGXFWIF_CMD3D` or a screen extent. It contains the FW 3D
context address and the client-CCB write offset/wrap mask. Firmware follows that
context to consume the client CCB, where KM copied `pui83DDMCmd` verbatim. Thus
the only remaining host-supplied, per-render place capable of independently
bounding the 3D walk is the not-yet-byte-diffed portion (or interpretation) of
the complete `RGXFWIF_CMD3D` image. The HWRT common object is the independent
render-target-level dimension source, but the named fields in it are shared
with TA and are already measured equal by the premise.

## Fragment-phase extent trace

### 1. UM command blob crosses the bridge unchanged

The kick ABI explicitly carries `pui83DCmd` and `ui323DCmdSize`
(`generated/rogue/rgxta3d_bridge/common_rgxta3d_bridge.h:328-375`). The generated
bridge passes its copied kernel buffer and size as `ui83DCmdInt` and
`ui323DCmdSize` to `PVRSRVRGXKickTA3DKM()`
(`generated/rogue/rgxta3d_bridge/server_rgxta3d_bridge.c:2088-2100`). The KM
function receives those as `pui83DDMCmd`/`ui323DCmdSize`
(`services/server/devices/rogue/rgxta3d.c:3683-3720`).

The multi-BVNC KM intentionally knows only the command's common prefix:
`CMDTA3D_SHARED` contains the frame number, `sHWRTData`, and PR-buffer FW
addresses (`include/rogue/rgx_fwif_shared.h:159-183`). KM patches
`sHWRTData` and optional Z/S and MSAA-buffer addresses in that prefix
(`services/server/devices/rogue/rgxta3d.c:3873-3915`). It does not reconstruct,
scale, shift, round, or otherwise edit the remaining `RGXFWIF_CMD3D` register
image.

The full command and exact byte count are then supplied to
`RGXCmdHelperInitCmdCCB_OtherData()`
(`services/server/devices/rogue/rgxta3d.c:5165-5208`) and released into the 3D
client CCB (`services/server/devices/rogue/rgxta3d.c:5280-5296`). This is the
per-kick fragment register state. The single-BVNC `RGXFWIF_CMD3D` definition is
not shipped in this multi-BVNC KM tree: only its size/`s3DRegs` ABI alignment
checks remain (`include/rogue/rgx_fwif_alignchecks.h:90-92`). Consequently this
repository cannot safely name every word after `CMDTA3D_SHARED`; it can and
should capture the complete bytes.

### 2. `s3DCmdKickData` points firmware at that CCB; it carries no extent

`RGXFWIF_KCCB_CMD_KICK_DATA` consists of `psContext`, client-CCB write offset,
wrap mask, cleanup controls, and (when enabled) a workload-estimation header
offset (`include/rogue/rgx_fwif_km.h:1110-1125`). The combined command merely
has one such descriptor for GEOM and one for FRAG
(`include/rogue/rgx_fwif_km.h:1127-1134`).

At submission KM fills the 3D context, write offset, and wrap mask
(`services/server/devices/rogue/rgxta3d.c:5396-5405`), embeds that descriptor in
a KCCB kick (`services/server/devices/rogue/rgxta3d.c:5454-5466`), and schedules
it on `RGXFWIF_DM_3D` (`services/server/devices/rogue/rgxta3d.c:5468-5473`). No
pixel, tile, or macrotile dimension is calculated on this path.

### 3. The command selects the independent FW HWRT dimension object

Both the TA and 3D command prefixes receive the same per-RT
`sHWRTDataFwAddr` (`services/server/devices/rogue/rgxta3d.c:3885-3906`). The
per-RT `RGXFWIF_HWRTDATA` contains region-header, macrotile-array, tail-pointer,
RTC, and VHeap addresses, but its dimension-dependent state is indirect through
`sHWRTDataCommonFwAddr` (`include/rogue/rgx_fwif_km.h:2453-2506`). KM assigns
that pointer when it creates each per-RT object
(`services/server/devices/rogue/rgxta3d.c:1670-1725,1747`).

`RGXFWIF_HWRTDATA_COMMON` is explicitly the render-target dimension-dependent
object. Its potentially extent-bearing fields are:

- `ui32ScreenPixelMax` (the ISP screen pixel maximum);
- `ui32TEScreen`, `ui32TEMTILE1`, `ui32TEMTILE2`, and `ui32MTileStride`
  (TE/macrotile grid setup);
- `ui32ISPMtileSize` (ISP macrotile sizing);
- `ui32TPCStride`, `ui32TPCSize`, and `uiRgnHeaderSize` (layout/stride and
  allocation bounds); and
- the ISP merge bounds and scales.

Their layout is visible at `include/rogue/rgx_fwif_km.h:2415-2437`. The create
ABI receives every value as an already-packed scalar
(`services/server/devices/rogue/rgxta3d.c:1927-1956`) and copies it unchanged
into FW memory (`services/server/devices/rogue/rgxta3d.c:1995-2021`). There is
no half-width/half-height conversion in KM.

This answers the independence question precisely: **yes**, RTData carries a
3D-consumed render-target dimension object independent of the geometry command
stream, but **no**, it does not carry a second KM-computed 3D-only width and
height. TA and 3D select the same HWRT/common object. A full TA region population
therefore does not prove that fragment firmware decoded every common-object
field identically, but it rules out a distinct KM-side “3D width = geometry
width / 2” assignment.

ZLS and PBE state in `RGXFWIF_CMD3D` controls depth/stencil and output storage;
it can clip/corrupt stores but is not a second enumerator of region headers.
Given `PROCESS_EMPTY_TILES`, a clean top-left quarter is stronger evidence for
an ISP/tile-grid limit or misdecoded command than for missing region content.

## Half-dimension audit

No per-axis divide, shift, sample-count conversion, pixel-to-tile conversion,
or default dimension exists in the examined KM path. The bridge copies the
opaque 3D command and HWRT-create scalars; the KM patches addresses only. In
particular:

- `s3DCmdKickData` cannot default to half size because it has no size field;
- TA and 3D use the same `sHWRTDataFwAddr`;
- `RGXCreateHWRTDataSet()` does no arithmetic on `ui32ScreenPixelMax`, the TE
  grid fields, `ui32MTileStride`, or `ui32ISPMtileSize`; and
- `ui32RenderTargetSize` on the kick is workload-estimation metadata, not a
  fragment extent (`services/server/devices/rogue/rgxta3d.c:3725-3729` and
  `:4999-5006`).

Therefore a half-by-half result must arise before KM in construction of the
opaque 3D register words, or after KM in FW interpretation/programming of those
words/HWRT common state. It is not introduced by visible KM arithmetic.

## Ranked remaining candidates

1. **Unmeasured word or ABI/layout error in the complete `RGXFWIF_CMD3D`
   register image.** This is the only per-kick, fragment-specific state passed
   through KM, and KM neither defines nor validates its BVNC-specific tail. A
   wrong field offset, omitted register, or stale open-FW/client definition can
   leave an ISP screen/tile-grid register at a value representing half the
   X and Y spans even while all currently enumerated fields compare equal.
   Evidence: the byte-blob bridge and CCB-copy trace above
   (`server_rgxta3d_bridge.c:2088-2100`; `rgxta3d.c:5165-5208`).

2. **FW ABI mismatch while reading `RGXFWIF_HWRTDATA_COMMON`.** The host static
   assertion proves the host-side object is 88 bytes, not that the executing
   open firmware uses identical field offsets and semantics. A stale FW layout
   could read a neighboring packed value as `ui32ScreenPixelMax` or
   `ui32ISPMtileSize`, yielding a deterministic smaller grid even though the
   KM-captured named values equal vendor. Evidence: the shared FW pointer and
   packed layout (`include/rogue/rgx_fwif_km.h:2415-2441,2469`) plus the direct
   population (`rgxta3d.c:1995-2021`). This ranks below the command image because
   the same object supports the already-proven full TA setup.

3. **FW-derived/private fragment state based on the correct common values.** A
   GE8300-specific decode, unit convention, or omitted FW register-programming
   step could halve each axis after the host inputs are correct. The KM supplies
   no further 3D dimension that can be logged to distinguish this directly.
   This is a downstream FW hypothesis and should only rise if both the complete
   command bytes and the FW-consumed common-object bytes are equal.

4. **ZLS/PBE extent or sample-unit mismatch.** These remain possible store-side
   explanations in the opaque command, but rank last for a walker-bound result:
   with empty-tile processing enabled, a rectangular quarter matching the walk
   origin is more naturally produced by ISP traversal bounds than by attachment
   storage. The premise also exonerates the known PBE and multisample words.

## Single decisive next experiment

Extend the existing bounded Odyssey ring capture by one record at the already
instrumented first-kick point: dump **exactly `ui323DCmdSize` bytes beginning at
`pui83DDMCmd`**, tagged as `kind=odyssey-3dcmd`, using the same base64 + SHA-256
format as `_OdysseyDumpGeomCmd()`. The suitable call site is immediately beside
the existing geometry-command capture at
`services/server/devices/rogue/rgxta3d.c:5622-5669`; the existing helper is at
`:272-335` and the ring drains through the visible
`PVRSRVReleasePrintf` path at `:130-164`.

Capture one known-full vendor render and one quarter open render, then perform a
byte-exact diff of the complete records (after accounting for the patched common
addresses). This one experiment is decisive because it covers the entire
fragment-specific input surface that this KM otherwise treats as opaque:

- a differing non-address word localizes the fault upstream to command
  construction and gives its exact byte offset for mapping to the single-BVNC
  `RGXFWIF_CMD3D::s3DRegs` definition;
- byte equality, together with the already-equal HWRT common named fields,
  eliminates KM/UM fragment-state construction and localizes the quarter to
  open-FW consumption/programming (including an FW ABI/layout mismatch).

Dumping only another named HWRT scalar is less decisive: those values have
already been observed, and the current Odyssey record already carries
`te_mtile1`, `te_mtile2`, `te_screen`, and `isp_mtile_size`
(`services/server/devices/rogue/rgxta3d.c:218-268`). The missing differential is
the full 3D command, not another geometry-side or common-object scalar.

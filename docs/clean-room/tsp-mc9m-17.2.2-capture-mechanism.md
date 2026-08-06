# ODYSSEY Phase-0 capture-mechanism decision

Bead: `tsp-mc9m.17.2.2`  
Parent: `tsp-mc9m.17.2`  
Decision: instrument the PocketForge-owned `gpu-km-tsp` (`Opt 1`).

## Executive decision

Use an opt-in diagnostic in the owned A133 `pvrsrvkm.ko`, centered on
`PVRSRVBridgeRGXCreateHWRTDataSet()` and `RGXCreateHWRTDataSet()`. The create
bridge is the exact closed-UM-to-KM receipt point: it copies region-header
device addresses from userspace and forwards those addresses plus all four
layout values without deriving them. This observes the closed UM's output
(values, addresses, and buffer data), not its implementation.

The scalar capture is straightforward. Capturing the bytes needs one additional
piece in the Phase-A patch: retain the PMR and reservation corresponding to each
reported region-header device virtual address when the existing devmem map path
runs, then acquire a temporary kernel mapping of that PMR at dump time. A device
virtual address is not a CPU pointer and must never be dereferenced directly.

## Evidence and answers

### Q1: which KM is used on the PocketForge A133 build?

**Answer: the PocketForge A133 build produces and names the owned KM
`pvrsrvkm.ko`; there is no separate shim in this KM path. Compatibility with a
particular packaged `libsrv_um.so` remains a deployment assertion that this
checkout alone cannot prove.**

The repository describes itself as the PocketForge-owned DDK 1.19 KM fork for
the A133 (`LICENSE:1-4`). Its A133 build entry point explicitly builds
`pvrsrvkm.ko` from this source, selects `PVR_SYSTEM=sunxi_a133`, and checks for
that output (`build-sunxi-a133.sh:1-3,43-64`). The A133 configuration fixes the
module name to `pvrsrvkm` and the DRM name to `pvr`
(`config_kernel_sunxi_a133.mk:19-25` and
`config_kernel_sunxi_a133.h:5-7,159`). The generated in-tree bridge registers
the HWRT-create operation directly and calls the owned
`RGXCreateHWRTDataSet()` implementation
(`generated/rogue/rgxta3d_bridge/server_rgxta3d_bridge.c:351-378`). There is no
shim between that bridge and the implementation.

The jailed source set did not contain the secondary `blobs` or
`test-node-farm` checkouts, so it was not possible here to cite their
`libsrv_um.so` packaging or initramfs module-selection files. Before the first
capture run, Phase A/the coordinator should verify from those sources that the
ODYSSEY image installs this built `pvrsrvkm.ko` and the matching DDK 1.19 UM.
Only if those source files disagree or remain ambiguous is a coordinator-held
DUT read needed: record the loaded module name/hash and the GPU device opened by
the process. No Phase-0 device access was attempted.

### Q2: is instrumentable vendor KM source available?

**Answer: yes; the necessary DDK KM source is already preserved in and owned as
this repository, so a second vendor-BSP checkout is not needed for Opt 1.**

`PROVENANCE.md:1-18,39-52` records that the complete Rogue DDK KM subtree was
extracted from a public Linux source tree and is maintained to build the A133
module. `LICENSE:8-25,30-32` records the applicable dual MIT/GPLv2 source
licensing, and `PROVENANCE.md:60-68` records the upstream file licensing. The
A133 platform layer is also present in source (`PROVENANCE.md:70-82`). This
answers the instrumentation-availability question for the selected mechanism;
whether some distinct BSP copy is available matters only if Opt 2 becomes
necessary.

### Q3: are the values and region-header buffers passed through the KM?

**Answer: yes for the four values and for the region-header buffer addresses.
The source positively establishes pass-through, not where the UM's algorithms
computed the values.**

The ABI input contains `ui32TEScreen`, `ui32TEMTILE1`, `ui32TEMTILE2`,
`ui32ISPMtileSize`, `ui32RgnHeaderSize`, and the region-header address-array
pointer (`generated/rogue/rgxta3d_bridge/common_rgxta3d_bridge.h:80-110`). The
bridge copies the address array from the caller
(`generated/rogue/rgxta3d_bridge/server_rgxta3d_bridge.c:275-294`) and passes it
and the scalar fields directly to `RGXCreateHWRTDataSet()`
(`generated/rogue/rgxta3d_bridge/server_rgxta3d_bridge.c:351-378`).

`RGXCreateHWRTDataSet()` receives those arguments
(`services/server/devices/rogue/rgxta3d.c:1521-1550`), copies the scalar values
unchanged into `RGXFWIF_HWRTDATA_COMMON`
(`services/server/devices/rogue/rgxta3d.c:1589-1615`), and forwards each
region-header address into `RGXCreateHWRTData_aux()`
(`services/server/devices/rogue/rgxta3d.c:1621-1639`). The auxiliary function
stores that address unchanged in the per-RT FW object
(`services/server/devices/rogue/rgxta3d.c:1270-1283,1343-1356`). The destination
structures independently identify those common fields and the region-header
base (`include/rogue/rgx_fwif_km.h:2415-2437,2482-2489`). No KM-side geometry
calculation intervenes.

The region-header *contents* are referenced by device virtual address rather
than copied through the HWRT-create ioctl. The ordinary mapping path already
associates a reservation base with a PMR
(`services/server/common/devicemem_server.c:839-919`), which gives the owned KM
a data-only route to the bytes; this requires the Phase-A diagnostic registry
described below.

### Q4: selected mechanism

Select **Opt 1: instrument owned `gpu-km-tsp`**. It is the narrowest trust
boundary, captures the UM-produced ABI data at its recipient, is fully
source-controlled, and avoids wrapping or inspecting the closed process. Opt 2
is reserved for evidence that ODYSSEY actually loads an incompatible vendor KM.
Opt 3 (`LD_PRELOAD` around ioctl) is last resort because it expands the trusted
capture surface into the closed process even though the ABI itself is fair
behavioral input.

## Phase-A instrumentation sketch

Keep the patch diagnostic-only and disabled by default (for example, a build
flag plus an apphint/debugfs enable). Bound every length and emit each capture
once per HWRT-data-set creation/capture id.

1. In `services/server/common/devicemem_server.c`, extend the diagnostic path
   around `DevmemIntMapPMR()`/`DevmemIntUnmapPMR()` to maintain a
   connection/context-scoped, refcounted mapping registry containing reservation
   base, length, PMR, and PMR offset. Do not expose this as production ABI.
2. In
   `generated/rogue/rgxta3d_bridge/server_rgxta3d_bridge.c::PVRSRVBridgeRGXCreateHWRTDataSet()`,
   after `OSCopyFromUser()` has made stable kernel copies and immediately before
   the call at lines 351-378, emit the scalar record and hand the copied
   `sRgnHeaderDevVAddrInt[]` plus `ui32RgnHeaderSize` to a small diagnostic helper.
   Because this file is generated, place reusable code in
   `services/server/devices/rogue/rgxta3d.c`/`.h` and document or update the
   generator input so regeneration does not silently remove the call.
3. In that helper, record exactly: `ui32TEMTILE1`, `ui32TEMTILE2`,
   `ui32TEScreen`, `ui32ISPMtileSize`, `ui32RgnHeaderSize`, RT index, and every
   `asRgnHeaderDevVAddr[]`. Resolve each address range through the diagnostic
   registry, use `PMRAcquireKernelMappingData()` for the bounded PMR subrange,
   emit exactly `ui32RgnHeaderSize` bytes (or a clearly marked failure), and
   release the mapping immediately. If the buffer is not populated until a
   later kick, retain the resolved, referenced record on
   `RGX_KM_HW_RT_DATASET` and invoke the same helper from the first successful
   `PVRSRVRGXKickTA3DKM()` path (`services/server/devices/rogue/rgxta3d.c:3277`
   onward); compare create-time and first-kick captures to settle timing.
4. Never cast/dereference the GPU virtual address, never dump beyond the reported
   size or reservation, and reject overflow, unmapped, sparse, protected, or
   non-kernel-mappable PMRs with a compact error record. Rate-limit total bytes
   per boot.

### Wire format

Use a single-line ASCII header followed by base64 payload brackets, shaped so
the existing framebuffer-emission decoder can share its delimiter parser:

```text
<<<PF-CAPTURE v=1 kind=odyssey-rgn id=<u64> rt=<u32> devva=<hex> bytes=<u32> te_mtile1=<hex> te_mtile2=<hex> te_screen=<hex> isp_mtile_size=<hex>>>
<RFC4648-base64, wrapped at 76 columns>
<<<PF-CAPTURE-END id=<u64> sha256=<64-lower-hex>>>
```

Use one bracketed record per RT buffer and repeat the scalar metadata on every
header so records remain independently decodable. `bytes` is decoded byte
length; `sha256` covers decoded bytes. On failure, emit a header with
`status=error reason=<stable-token>` and an immediate end delimiter with no
payload. If the exact `tsp-idh7.1` framebuffer delimiter constants are available
to Phase A, substitute those literal begin/end tokens while keeping
`kind=odyssey-rgn` and these metadata fields; that source was not present in this
checkout, so this memo does not invent a claim about its literal spelling.

## Clean-room boundary

This mechanism reads **NO blob CODE**. This investigation read only owned/open
KM source. It did **not** open,
disassemble, decompile, scan, or otherwise read blob code, and it performed no
DUT operation. The selected diagnostic observes values, addresses, and bytes
submitted by the closed UM at the documented ABI boundary: behavioral data
only.

This bead is the spec-extractor step. Its output may describe observed behavior
but must contain no verbatim closed implementation. The later Phase-A capture
worker and especially the v1-geometry implementer remain separate beads/roles;
the geometry implementer consumes the promoted functional memo/captures and
does not read the closed UM. Owner/counsel authorization is recorded on
`tsp-mc9m` (baton `ck-43/45`).

# RE-FINDINGS-53: geometry-command framing and decode

Date: 2026-08-29
Bead: `tsp-mc9m.41.723`

## Result

There is **no `0xc002` register-write opcode in the captured vendor geometry
payload**.  The 72 bytes are exactly the fixed GE8300/DDK-1.19
`rogue_fwif_cmd_ta` (`RGXFWIF_CMDTA`) payload.  Consequently:

- `0xc0028640` is `cmd_shared.hw_rt_data.addr`, a 32-bit firmware virtual
  address;
- `0xc0028140` is `cmd_shared.pr_buffers[ZSBUFFER].addr`, another firmware
  virtual address; and
- `0xc002b004` is `partial_render_ta_3d_fence.ufo_addr.addr`, the address of a
  firmware UFO/sync word.

None targets CR `0x8640`, `0x8140`, or `0xb004`, and none controls ISP, TE,
tiling, screen size, macrotile layout, tile walking, or render extent.

The apparent opcode theory arose by comparing two different layers.  The
vendor capture records the post-UM, KM-patched firmware payload.  The open
capture records the compact Mesa-to-KMD stream *before* the KMD expands it and
patches its shared fields.  Once the open stream is parsed, both paths contain
the same set of named geometry register values.  The open path does **not**
omit a vendor ISP/tiling register write.  There are value differences worth a
matched-render test, but no extra vendor register opcode.

## Evidence convention and source snapshots

- **MEASURED** means a value is present in the two supplied ring captures.
- **SOURCE-DECODED** means source layout/bit definitions determine the decode.
- **INFERRED** means the source and captures support the interpretation but the
  exact post-parse open payload was not captured at the vendor hook.
- **NOT ESTABLISHED** marks conclusions the two captures cannot support.

Line citations use these snapshots:

- `gpu-km-tsp@fbb38f3f712a9b151f7482450bafd939b8269ae8` (this bead's base);
- `gpu-um-tsp@2546a5ad4f89bd09478874f3f6660567489947ec`
  (`main` fetched 2026-08-29); and
- `kernel-sunxi-6.x@136518888335c0b23494690ed08f933e64a3f3dd`
  (`device/a133`).

## 1. What the vendor capture actually contains

### 1.1 The CCB opcode/header is outside the captured bytes

The DDK defines the geometry CCCB type separately as
`RGXFWIF_CCB_CMD_TYPE_GEOM`; it is formed from the `0x2abc` command magic,
task bit, and type 201 (`gpu-km-tsp/include/rogue/rgx_fwif_km.h:1029`,
`:1032`, `:1749`, `:1758`).  A CCB command header then carries `eCmdType`,
payload size, and job references before the type-specific data
(`gpu-km-tsp/include/rogue/rgx_fwif_km.h:1802`, `:1807-1816`).

The Odyssey hook does not dump that header.  It passes `pui8TADMCmd` and
`ui32TACmdSize` directly to `_OdysseyDumpGeomCmd`
(`gpu-km-tsp/services/server/devices/rogue/rgxta3d.c:5668`); the receiving KM
entrypoint identifies those arguments as the TA command size and TA command
payload (`gpu-km-tsp/services/server/devices/rogue/rgxta3d.c:3683`,
`:3707-3708`).  The first dword is therefore the first payload field, not an
opcode.

For the requested `0xc002` command-format decode, the answers are therefore
`opcode = N/A`, `word count = N/A`, and `register-address field = N/A`.
`0xc002` is merely the common high halfword of three captured firmware virtual
addresses; it is not split from the low halfword by this ABI.

### 1.2 Why the first four dwords are firmware addresses

The shared prefix is explicitly shared among UM, KM, and firmware.  It is a
common/frame field followed by the HWRT-data firmware address and two PR-buffer
firmware addresses (`gpu-km-tsp/include/rogue/rgx_fwif_shared.h:159-162`,
`:164-183`).  Each `RGXFWIF_DEV_VIRTADDR` is one `IMG_UINT32 ui32Addr`
(`gpu-km-tsp/include/rogue/rgx_fwif_shared.h:87-90`).  The KM casts the start of
`pui8TADMCmd` to this shared prefix and patches the HWRT-data, Z/S-buffer, and
MSAA-buffer firmware addresses before the Odyssey dump
(`gpu-km-tsp/services/server/devices/rogue/rgxta3d.c:3873-3898`).

The equivalent open definition says why these are kernel-patched: UM holds
handles rather than raw firmware addresses, so the KMD writes the addresses
into the shared prefix (`gpu-um-tsp/src/imagination/vulkan/winsys/pvrsrvkm/fw-api/pvr_rogue_fwif_shared.h:129-152`).

### 1.3 Dword-by-dword vendor decode

The GE8300/DDK-1.19 definition fixes this structure at 72 bytes and pins the
important offsets: `ppp_ctrl` at 32, `te_psg` at 36, `tpu` at 40, flags at 56,
and the partial-render fence at 60
(`gpu-um-tsp/src/imagination/vulkan/winsys/pvrsrvkm/fw-api/pvr_rogue_fwif.h:248-261`).
The member order is defined at the same file's lines 154-190 and 209-242.

| DW | Byte | Captured LE32 | SOURCE-DECODED field | Decode |
|---:|---:|---:|---|---|
| 0 | `0x00` | `00000001` | `cmd_shared.cmn.frame_num` | **MEASURED:** frame 1. The common field is defined at `pvr_rogue_fwif_shared.h:117-127`. |
| 1 | `0x04` | `c0028640` | `cmd_shared.hw_rt_data.addr` | **MEASURED/SOURCE-DECODED:** 32-bit firmware address `0xc0028640`; not an opcode and not CR `0x8640`. |
| 2 | `0x08` | `c0028140` | `cmd_shared.pr_buffers[ZSBUFFER].addr` | **MEASURED/SOURCE-DECODED:** Z/S PR-buffer firmware address `0xc0028140`; not CR `0x8140`. Z/S is PR-buffer index 0 (`pvr_rogue_fwif_shared.h:89-92`). |
| 3 | `0x0c` | `00000000` | `cmd_shared.pr_buffers[MSAABUFFER].addr` | **MEASURED:** no MSAA scratch-buffer firmware address. MSAA is PR-buffer index 1 (`pvr_rogue_fwif_shared.h:89-92`). |
| 4 | `0x10` | `01623060` | `regs.vdm_ctrl_stream_base` low | Together with DW5, `0x0000008001623060`. This is the geometry VDM control-stream GPU address. The field is `u64` (`pvr_rogue_fwif.h:154-156`); address bits/2-byte alignment are defined by `gpu-um-tsp/src/imagination/csbgen/rogue/cr.xml:168-170`. |
| 5 | `0x14` | `00000080` | `regs.vdm_ctrl_stream_base` high | High 32 bits of the preceding address. |
| 6 | `0x18` | `0044f400` | `regs.tpu_border_colour_table` low | Together with DW7, `0x000000200044f400`, the VDM TPU border-colour table address. The field is `u64` (`pvr_rogue_fwif.h:155-157`); its address field is defined at `cr.xml:658-660`. |
| 7 | `0x1c` | `00000020` | `regs.tpu_border_colour_table` high | High 32 bits of the preceding address. |
| 8 | `0x20` | `00000303` | `regs.ppp_ctrl` | `fixed_point_format=1`, `default_point_size=1`, `wclampen=1`, `opengl=1`; all other defined bits clear (`cr.xml:436-449`). Geometry/PPP setup, not an extent. |
| 9 | `0x24` | `00020000` | `regs.te_psg` | `completeonterminate=1`; defined region-stride field is 0 (`cr.xml:380-396`). This is the only explicitly TE/parameter-management field in the payload, but it is a value, not an encoded write opcode. |
| 10 | `0x28` | `00000021` | `regs.tpu` | `tag_cem_4k_face_packing=1` and `madd_config_dxt35_transovr=1` (`cr.xml:636-652`). Texture-parameter controls, not screen/tile extent. |
| 11 | `0x2c` | `00010000` | `regs.vdm_context_resume_task0_size` | USC common size field 1, whose unit is 64 bytes (`gpu-um-tsp/src/imagination/csbgen/rogue/vdm.xml:100-116`). Geometry context-resume sizing, not ISP extent. |
| 12 | `0x30` | `00005f00` | `regs.view_idx` | **MEASURED:** low view index is 0; undocumented high byte is `0x5f`. The public KMD-stream definition only assigns bits 7:0 to `idx` (`kmd_stream.xml:124-126`), so the meaning of bits 15:8 is **NOT ESTABLISHED** by these headers. |
| 13 | `0x34` | `00000000` | `regs.padding` | Structure padding (`pvr_rogue_fwif.h:183-190`). |
| 14 | `0x38` | `00100007` | `flags` | Defined low bits 0/1/2 mean first kick, last kick, and flip sample positions (`pvr_rogue_fwif.h:93-104`). Bit 20 (`0x00100000`) is not named in the public flag definitions at lines 97-119; its meaning is **NOT ESTABLISHED**. |
| 15 | `0x3c` | `c002b004` | `partial_render_ta_3d_fence.ufo_addr.addr` | **MEASURED/SOURCE-DECODED:** firmware UFO/sync address `0xc002b004`; not CR `0xb004`. A UFO is address plus comparison/update value (`pvr_rogue_fwif_shared.h:71-79`), and the SRV builder fills this field from a firmware sync-primitive address (`pvr_arch_srv_job_render.c:572-574`). |
| 16 | `0x40` | `00000000` | `partial_render_ta_3d_fence.value` | Fence comparison value 0. |
| 17 | `0x44` | `00000000` | command `padding` | Final structure padding (`pvr_rogue_fwif.h:241-242`). |

This layout consumes all 18 dwords without an opcode/data interpretation and
matches every source-pinned offset.

## 2. The alleged CR addresses

| Captured word | Alleged decode | Actual decode | ISP/TE/tiling relevance |
|---|---|---|---|
| `c0028640` | write CR `0x8640` | HWRT-data firmware virtual address | None; selects the firmware HWRT object. |
| `c0028140` | write CR `0x8140` | Z/S PR-buffer firmware virtual address | None; points at buffer-management state. |
| `c002b004` | write CR `0xb004` | partial-render UFO firmware virtual address | None; synchronization only. |

The DDK's autogenerated KM CR header uses ordinary explicit address macros—for
example, `RGX_CR_RASTERISATION_INDIRECT` is `0x8238`,
`RGX_CR_USC_INDIRECT` is `0x8000`, and `RGX_CR_PBE_INDIRECT` is `0x83e0`
(`gpu-km-tsp/hwdefs/rogue/km/rgx_cr_defs_km.h:63-87`).  A repo-wide exact
search finds no CR definition at `0x8640`, `0x8140`, or `0xb004`:

```sh
rg -n '0x8640|0x8140|0x[Bb]004' hwdefs/rogue/km/rgx_cr_defs_km.h
```

That negative search is corroborative, not the primary proof; the positive
structure/offset match above is the proof.

## 3. Open compact stream decode

### 3.1 Framing

`KMD_STREAM_HDR` is **two dwords**, not one: a 32-bit byte length followed by
padding (`gpu-um-tsp/src/imagination/csbgen/rogue/kmd_stream.xml:111-113`).
The open KMD independently reads the length and requires the second dword to be
zero (`kernel-sunxi-6.x/drivers/gpu/drm/imagination/pvr_stream.c:217-231`).
Thus header value `0x28` means the main stream ends at byte 40.  Bytes 40-47
are a one-dword geometry extension header and one-dword extension payload.

Mesa emits the main fields in this exact order: header, VDM control-stream
base, VDM TPU border-colour table, PPP control, TE PSG, VDM/PDS resume state,
and view index (`gpu-um-tsp/src/imagination/vulkan/pvr_arch_job_render.c:830-899`).
It then emits an extension header and `CR_TPU` for BRN49927
(`pvr_arch_job_render.c:901-935`).  The kernel's stream definition maps the
same main fields and the BRN49927 extension into the firmware geometry command
(`kernel-sunxi-6.x/drivers/gpu/drm/imagination/pvr_stream_defs.c:46-74`).

### 3.2 Dword-by-dword open decode

| DW | Byte | Captured LE32 | SOURCE-DECODED field | Decode |
|---:|---:|---:|---|---|
| 0 | `0x00` | `00000028` | `KMD_STREAM_HDR.length` | **MEASURED:** main stream length 40 bytes. |
| 1 | `0x04` | `00000000` | `KMD_STREAM_HDR` padding | Required zero. |
| 2 | `0x08` | `00516000` | `CR_VDM_CTRL_STREAM_BASE` low | With DW3, address value `0x0000008000516000`. |
| 3 | `0x0c` | `00000080` | `CR_VDM_CTRL_STREAM_BASE` high | High 32 bits. |
| 4 | `0x10` | `0001a400` | `CR_TPU_BORDER_COLOUR_TABLE_VDM` low | With DW5, address value `0x000000200001a400`. |
| 5 | `0x14` | `00000020` | border-colour address high | High 32 bits. |
| 6 | `0x18` | `00000202` | `CR_PPP_CTRL` value | `fixed_point_format=1`, `wclampen=1`; unlike vendor `0x303`, default point size and OpenGL mode are clear (`cr.xml:436-449`). |
| 7 | `0x1c` | `00020001` | `CR_TE_PSG` value | `completeonterminate=1`, `region_stride=1` (4096-byte unit); vendor captured 0 (`cr.xml:380-396`). |
| 8 | `0x20` | `20010000` | VDM `PDS_STATE0`/`vdm_context_resume_task0_size` value | PDS-state-update block type (1 in bits 31:29) plus USC common size 1 (`vdm.xml:30-39`, `:100-116`). Vendor carries only `0x00010000`. |
| 9 | `0x24` | `00000000` | `KMD_STREAM_VIEW_IDX` | view index 0; the defined field occupies only bits 7:0 (`kmd_stream.xml:124-126`). |
| 10 | `0x28` | `00000001` | `KMD_STREAM_EXTHDR_GEOM0` | `has_brn49927=1` (`kmd_stream.xml:105-109`). |
| 11 | `0x2c` | `00000020` | extension `CR_TPU` value | `tag_cem_4k_face_packing=1`; vendor additionally sets bit 0 (`cr.xml:636-652`). |

The SRV winsys parser is a useful executable specification of the layer
conversion: it strips the header and assigns the main values to named
firmware-command members (`gpu-um-tsp/src/imagination/vulkan/winsys/pvrsrvkm/pvr_arch_srv_job_render.c:470-509`),
then assigns the extension TPU value (`pvr_arch_srv_job_render.c:512-535`).
At the cited snapshot, the experimental SRV loader deliberately ORs `0x5f00`
into `view_idx` after reading the compact word (`pvr_arch_srv_job_render.c:499-504`);
that is a post-stream SRV-path override, not a field in the measured DRM raw
stream.  The initializer zeroes the full command, fills the shared frame
number, and adds flags/fence outside the KMD stream
(`pvr_arch_srv_job_render.c:537-574`).

On the operative DRM path the open KMD performs the same semantic conversion:
it allocates the destination firmware-command object, parses the compact
stream, then fills frame/flags/HWRT address
(`kernel-sunxi-6.x/drivers/gpu/drm/imagination/pvr_job.c:67-100`,
`:142-167`).  The queue fills the partial-render UFO immediately before
submission (`kernel-sunxi-6.x/drivers/gpu/drm/imagination/pvr_queue.c:667-680`).

## 4. Aligned comparison

The correct alignment is not “72 bytes versus 48 bytes.”  It is:

```text
open 48-byte Mesa KMD stream
  -> KMD parser + shared-field/flag/fence patching
  -> firmware geometry-command structure

vendor UM firmware geometry-command structure
  -> shared-field patching in vendor KM
  -> captured 72-byte firmware geometry-command structure
```

At the firmware-command semantic layer, both contain:

1. frame/HWRT/PR-buffer shared fields;
2. VDM control-stream address;
3. VDM TPU border-colour-table address;
4. PPP control;
5. TE PSG;
6. BRN49927 TPU control;
7. VDM context-resume task-0 size/state;
8. view index;
9. geometry flags; and
10. partial-render UFO.

The apparent vendor-only words are simply fields the open UAPI intentionally
does not trust UM to supply (`hw_rt_data`, PR-buffer addresses, and UFO), or
fields supplied in the separate DRM job arguments (`flags`).  They are present
in the open firmware command after KMD processing.

### 4.1 Values that genuinely differ in the supplied captures

| Semantic field | Vendor payload | Open compact stream | Classification |
|---|---:|---:|---|
| VDM control-stream address | `0x0000008001623060` | `0x0000008000516000` | Per-run GPU allocation; expected to differ. |
| TPU border-colour-table address | `0x000000200044f400` | `0x000000200001a400` | Per-stack allocation; expected to differ. |
| `PPP_CTRL` | `0x00000303` | `0x00000202` | Vendor additionally sets default-point-size and OpenGL-mode bits. Not an extent control. |
| `TE_PSG` | `0x00020000` | `0x00020001` | **Tiling-adjacent:** region-header stride field 0 versus 1; both set complete-on-terminate. This is a value delta, not an omitted register. |
| `TPU` | `0x00000021` | `0x00000020` | Vendor additionally sets DXT3/5 transpose override. Not an extent control. |
| VDM resume task-0 value | `0x00010000` | `0x20010000` | Open additionally carries the PDS-state-update block-type bit. Geometry context state, not an ISP extent. |
| `view_idx` | `0x00005f00` | `0x00000000` | Vendor carries undocumented high byte `0x5f`; public definition covers only low byte. Dynamic residual, but not identified as an ISP/tiling register. |
| flags/shared/UFO | present in 72-byte vendor payload | outside 48-byte open compact stream | **NOT COMPARABLE from these captures**; KMD supplies them later. |

The captures alone do not prove that the two jobs had identical allocation,
resolution, termination, flags, or region-header-stride inputs.  Therefore the
table identifies deltas; it does not claim causality.

### 4.2 Which ISP/tiling/screen/macrotile/tile-walk write does open omit?

**None evidenced.**  In particular:

- Both paths contain `TE_PSG`; the open value differs only in its low
  region-stride field.
- Neither geometry payload contains `TE_SCREEN`, `TE_MTILE1/2`,
  `ISP_MTILE_SIZE`, `PPP_SCREEN`, or `FRAG_SCREEN`.  Those are distinct state
  definitions (for example, `TE_MTILE1/2` and `TE_SCREEN` are defined at
  `gpu-um-tsp/src/imagination/csbgen/rogue/cr.xml:363-378`, while
  `FRAG_SCREEN` is at `:631-634`).
- `0xc0028640`, `0xc0028140`, and `0xc002b004` are positively decoded firmware
  pointers, not hidden CR writes.

This finding closes the proposed “vendor emits an extra ISP/tiling register
write” lever.  It does **not** close dynamic-command differences: the differing
values above, especially the unexplained `view_idx[15:8]`, remain legitimate
runtime-state leads.

## 5. Ranked next tests

Do not make open emit a synthetic `0xc002xxxx` write: that would replace a
firmware pointer with invented command syntax and would not reproduce the
vendor path.

Instead, use this bounded, matched-render sequence.  The ranking is by direct
connection to tiling first, then by unexplained dynamic difference:

1. **`TE_PSG.region_stride` matched-value test (only tiling-adjacent delta).**
   Capture the post-parse open firmware geometry command for the same
   resolution/RT layout as vendor.  If vendor remains 0 and open remains 1,
   override only bits 10:0 of open `cmd->regs.te_psg` to the vendor value after
   `pvr_stream_process()` in `pvr_geom_job_fw_cmd_init()`; preserve bit 17 and
   all other fields.  Re-measure coverage.  Full coverage would identify a
   TE parameter-region-stride interaction; unchanged quarter coverage rules it
   out.
2. **`view_idx[15:8]=0x5f` on the operative DRM path.**  After open KMD stream
   parsing, set
   `cmd->regs.view_idx = (cmd->regs.view_idx & 0xffff00ff) | 0x00005f00`, dump
   the post-parse field to prove the change reached the submitted command, and
   re-measure coverage.  This targets the actual open DRM command; changing the
   SRV-only loader does not prove the DRM path changed.  Full coverage makes
   the high byte the dynamic lever; unchanged quarter coverage rules it out as
   an extent cause.
3. **VDM resume-word normalization.**  With tests 1-2 negative, clear only the
   open-only `0x20000000` PDS block-type bit so the submitted value is vendor's
   `0x00010000`; preserve the common-size field.  Re-measure.  This probes a
   geometry context-state difference, not an ISP register omission.
4. **PPP/TPU value controls.**  Only after the preceding tests, reproduce
   vendor `PPP_CTRL=0x303` and `TPU=0x21` one at a time with readback/dump
   evidence.  Their documented meanings are point/OpenGL and texture-format
   controls, so they rank below the TE and unexplained view-index deltas.

Before any A/B, add one open post-parse dump at the same layer as Odyssey's
hook.  It must include the semantic fields plus flags/shared/UFO after KMD
patching.  That positive alignment control prevents another compact-stream
versus firmware-structure comparison from manufacturing a false omission.

## Conclusion

**SOURCE-DECODED verdict:** the three `c002`-prefixed dwords are firmware
addresses in a 72-byte geometry structure.  They are not opcodes, do not name
CRs, and reveal no omitted open ISP/tiling/tile-walk register write.  The
dynamic investigation should move to matched, post-parse value differentials:
first the only TE-adjacent delta (`TE_PSG.region_stride`), then the unexplained
vendor `view_idx` high byte, followed by the VDM/PPP/TPU differences.

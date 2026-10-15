# Geometry-shader draws on Metal (P7.1, D12)

Status: design, 2026-10-15.

## What the game uses

The two pipelines in the clinic bench (`BB_DUMP_SHADERS=1` with a diagnostic build that reports
`geometry_stage` on Metal; both backends skip these draws on macOS today, ~4.3k warnings per bench
run):

| GS | Input | Output | Max vertices | In attrs | Out attrs | Target |
|---|---|---|---|---|---|---|
| `0x8e3f8dc4` | points | triangle strip | 8 (2 quads) | 6 | 6 + position | 1 colour target, blended, depth |
| `0x1635154c` | points | triangle strip | 40 (1 `EndPrimitive` every 4: up to 10 quads) | 14 | 2 + position | the same |

Both are particle-style point → quad expansions: one invocation (`Invocations 1`), no loops (the
recompiler unrolled them), resources: the push block, one SSBO, `bda_pagetable`. No
`vgt_gs_mode.onchip`, no stream-out.

## Decision: compute pre-pass, not mesh shaders

The draw becomes three steps of one command buffer, the shape of the tessellated draws (P4.4):

1. **ES kernel**: the export shader (SPIR-V vertex stage) compiled as SPIRV-Cross' tessellation
   vertex kernel (`CompileVariant::TessVertex`): one thread per input vertex, stage-in vertex
   fetch, index buffer, outputs captured into a scratch buffer (`main0_out`, one struct per draw
   position). Unchanged from tessellation.
2. **GS kernel**: the geometry shader rewritten on the SPIR-V level into a compute shader
   (`mtl_spirv_geometry`): one thread per input primitive. It reads its input vertices from
   step 1's buffer at the byte offsets SPIRV-Cross gave each output location (reflected when
   step 1 compiles), and turns `OpEmitVertex`/`OpEndPrimitive` into stores: a fixed-layout vertex
   record per emitted vertex (position, then one 16-byte slot per output location) at
   `prim * max_vertices + n`, and a strip index list of `2 * max_vertices` uint32 per primitive
   (the record index per emitted vertex, `0xFFFFFFFF` at `EndPrimitive` and for every unused
   slot).
3. **Draw**: an indexed triangle-strip (line-strip) draw of `prims * 2 * max_vertices` uint32
   indices in the render pass; Metal always restarts strips at `0xFFFFFFFF`. The vertex function
   is a generated pass-through (MSL text) that reads the record of `[[vertex_id]]` and outputs
   position plus `[[user(locnK)]]` members typed as the fragment shader declares them; it applies
   the [-w, w] → [0, w] depth conversion that the recompiler only emits for hardware VS stages
   (key `clip_space == MinusWToW`, Metal has no `depth_clip_control`).

Steps 1 and 2 are compute work before the pass: the held-pass hoisting of P6.2 applies as it does
to the tessellation kernels.

Why not mesh shaders (Metal object/mesh functions):
- SPIRV-Cross translates neither geometry shaders nor a geometry → mesh conversion; either way
  the GS is rewritten by us, and a mesh function would also have to embed the ES (its vertex
  fetch is SPIRV-Cross' stage-in, which exists for vertex shaders and tessellation kernels only).
- The pre-pass reuses what already works: the ES kernel, scratch spans of the staging ring, the
  kernel hoisting before the pass, the resource binding of a stage into a compute encoder.
- The cost is small here: a few GS draws a frame, bounded output (8 and 40 vertices a point).
A mesh path stays possible later if GS draws turn out to be expensive.

Limits of the first version (counted and logged when hit, draws dropped): input primitives other
than point, line and triangle lists; `Invocations > 1`; output points; more than one instance;
indirect draws; `onchip`/stream-out (the core already skips those). Large draws are split into
chunks of primitives so one span of the staging ring holds a chunk.

## Slots

The GS kernel keeps its own resources below `kTessFirstReservedBuffer` (13), like the tessellation
variants, and uses: 13 the ES outputs (input), 14 vertex records (output), 15 strip indices
(output), 16 parameters (`{prim_count, first_prim}`, the GS reads `gl_PrimitiveID` as
`first_prim + thread`). The pass-through vertex function reads the records at buffer 0.

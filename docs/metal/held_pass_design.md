# Held render passes on Metal (P6.2)

Status: design, 2026-10-15. Owner of the scheduler part: the orchestrator; `RenderList` and the
rasterizer conversion: porter task P6.2a.

## Why

The P6.1 trace of the clinic (m4air, 540p) has ~335 encoders a frame (177 render, 100 compute,
54 blit). The render passes are cut by work the Vulkan path moves out of the way:

| Cut | Encoders a frame | What happens on Metal today |
|---|---|---|
| tessellated draws (`960x540 C1 D`, ~50) | ~100 | the pass ends, the VS/TCS kernels run in a compute encoder, the pass is begun again (loading) |
| the game's copy shader `fefebf9f` (~32) | ~64 | it splits the G-buffer pass (6 colour targets + depth) each time |
| bloom chain blits between small passes | 54 | blit encoders between passes |
| HUD draws switching between passes with and without depth | ~20 | a new pass for every switch |

Encoders cost CPU (`renderCommandEncoderWithDescriptor` was 17.6% of the recording thread), and
every split pass stores and reloads its targets. On Vulkan the core hoists such dispatches before
a *held* pass (`RasterizerCore::HoistDispatch`, `GpuQueue::BeginHoist/EndHoist`): G-buffer 20 → 7
encoders. Metal recorded immediately and could not put anything before an open encoder.

## Design

- **`RenderList`** (`mtl_render_list.h/.mm`): the rasterizer's render-encoder calls (pipeline and
  fixed-function state, buffers/textures/samplers/bytes per stage, vertex buffers with stride,
  tessellation factor buffer, draws, in-pass barriers, signposts) go through it. Direct mode
  forwards to the encoder; recording mode appends to a byte arena that is replayed into the encoder
  later. Both drop redundant state (same object in the same slot since the pass began).
- **Held pass** (`Scheduler::RenderEncoder(desc, state)`, `BB_MTL_HOLD=1`, default): no encoder
  is made; `holding`, `++held_serial` (the core's per-pass access sets key on it), the descriptor
  is kept, the list records.
- **Hoisting**: between `BeginHoist` and `EndHoist`, `ComputeEncoder()` opens (once per held pass)
  a real compute encoder in the command buffer: it lies before the pass's render encoder, which
  does not exist yet. It waits for the fences of everything before it (Vulkan's barrier before a
  hoisted dispatch); the render encoder waits for its fence (the barrier after).
- **Release** (`ReleaseHeldPass`, from `EndEncoder`: another pass, a non-hoisted dispatch, a
  transfer, `Flush`, debug groups): end the hoisted compute encoder, make the render encoder from
  the kept descriptor (waiting for earlier fences when something was hoisted or a barrier was
  recorded), replay the list, continue the pass in direct mode (as Vulkan's pass "goes on unheld").
- **Users**: the core's `HoistDispatch` → `Metal::Rasterizer::RecordHoistedDispatch` (the copy
  shader); tessellated draws: when `RasterizerCore::CanHoistDrawWork()` (the draw's reads were not
  written by the pass's earlier draws, its writes not read by them, its images not the pass's), the
  VS/TCS kernels are hoisted and the patch draw stays in the pass.
- **Lifetime**: the list holds plain pointers. Objects are destroyed through `DeferOperation` at the
  current tick, i.e. after the command buffer that contains the replay has completed; the list is
  always replayed before its command buffer is committed (`Flush` releases first). The kept pass
  descriptor is a strong reference.

## Not in this step

Merging the HUD's depth/no-depth passes (a pass with depth stays open for draws without depth, using
the depth-format pipeline with depth tests off), the bloom blits (look at what they are in a
labelled trace first), and encoding the list on another thread or in parallel (P6.5).

Later (P8.6, d9619bc): a pass released because the next held pass begins is encoded on the
scheduler's replay thread (`bb:MtlReplay`, up to `Scheduler::ReplayDepth` passes in flight, in
order). The list moves to the job (`RenderList::TakeRecording`), the descriptor to
`Impl::replay_passes`; the job ends the hoisted compute encoder, makes the render encoder (with
the fence wait the release would have done), replays and ends it. Every scheduler member that
touches the encoders, the fences or the command buffer joins the jobs first (`JoinReplay`); the
recorded calls of the next held pass do not. Lifetimes are unchanged: the jobs finish before
Flush commits, and the tick does not advance before. `BB_MTL_REPLAY_THREAD=0` or experiment bit
45 (`MtlNoReplayThread`) encodes on the recording thread as before.

## Checks

Unit tests (`macos/test.sh`), build, display dumps A/B within one run (`BB_MTL_HOLD` is read at
start: two runs, same camera; plus `ab.sh` once a runtime switch exists), encoders per frame from a
trace (`mtltrace.py`), 5 min `m1_run.sh` with `MTL_DEBUG_LAYER=1`, the Metal FPS pair.

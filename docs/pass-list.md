# Pass list

The game owns `RenderSettings` and builds an `Overlay` each tick. `FramePacket` borrows the overlay and scene draws until `engine_render` returns. Game temporary storage releases them at the end of the tick, including when rendering skips.

A frame is described as data, then recorded in one place, the way RAD Debugger's `R_PassList` and `r_window_submit` do it. `ctx` and `engine` are passed explicitly; nothing here is a global.

`engine_render` synchronizes draw history before acquiring a frame. Acquisition and target resize precede the build. Shader reload invalidates the shadow cache before planning, and shadow caster sync updates retained bounds before filtering.

## Build

`frame_build` reads an explicit `FrameInput` and returns the pass list, the host uploads and the shadow plan. It chooses passes, filters shadow views, chooses CPU or GPU culling, and assigns instance and indirect spans. With `settings.gpu_cull`, main and every shadow view cull on the GPU, or the whole frame falls back to the CPU filter. It does not record commands or change the history, shadow cache, or GPU state. Odin does not enforce read-only pointers; callers must preserve this contract.

```odin
Pass :: union {
	ParticlesPass,
	CullPass, // one dispatch for every GPU-culled view; absent when nothing culls on the GPU
	ShadowPass, // one per atlas that has views
	ClustersPass,
	MainPass,
	BloomPass,
	TonemapPass,
	OverlayPass,
}

frame_build :: proc(input: FrameInput) -> (passes: []Pass, uploads: FrameUploads, shadow_plan: ShadowPlan)
```

Each pass kind is one struct holding everything that pass records. A skipped pass is not appended: there is no enable table. The list is in execution order. `main_pass_build`, `shadow_passes_build`, `post_passes_build` and the other `*_pass_build` procs live in the feature's file next to its `record_*` proc, so `frame_checks` can call them directly.

`LayoutBuilder` owns the shared instance and indirect budgets. Packing order is 2D shadow views, cube shadow views, main opaque draws, then transparent draws, fixed by `frame_build`'s call order (not by list order: particles, which allocate nothing, are appended first). `src/graphics/frame_layout.odin` owns building, uploading and encoding these spans. GPU cull outputs use separate buffers and capacities.

`CullBuilder` collects the GPU path. Main goes in first, so its candidates, batches and outputs sit at index 0 of each buffer; `gpu_cull_collect` and the validator read only that range. The shadow casters are uploaded once as shared candidates, and each shadow view adds its own batches over that range (up to `GPU_CULL_BATCH_CANDIDATES` each) with their own output range and a view in the views buffer (up to four frustums, so a directional light's cascades are one view; `skip_near` for directional). Candidates, outputs and batches each draw from `FrameBudget` (batches also stay within `GPU_CULL_MAX_BATCHES`, the dispatch-y limit). If any overflows, `frame_build` builds the frame again on the CPU path for main and shadows alike. `CullPass` is inserted ahead of every shadow pass and `MainPass`; `record_cull` runs init, test (x over a batch, y the batch) and compact over all batches. Indirect overflow produces direct draws; instance overflow drops the remaining runs in that allocation request.

The pass list is not the only output. `FrameUploads` (scene data, lights, transforms, the layout spans) and the `ShadowPlan` are frame-wide and belong to no single pass, so they travel beside the list as plain values. The cull upload belongs to `CullPass`; `frame_upload` finds it in the list. The uploaded overlay lives in `Recorder.overlay`, not in `OverlayPass`.

Bloom and tonemap come from one `post_passes_build` call, so the level count is computed once and `bloom_strength / levels` always agrees with the number of levels bloom runs.

## Record

```odin
passes_record :: proc(r: ^Recorder, passes: []Pass)
```

One `switch` on the pass kind. Each case opens the pass's timing scope after issuing its barriers, then calls the `record_*` proc that lives in the feature's file. `pass_uses(pass)` declares the `{FrameResource, ImageStateKind}` each pass needs before it starts; the barriers derive from it. `MainPass` and `OverlayPass` declare both shadow atlases `Depth_Read`, which is what leaves them readable when the shadow passes are skipped. Intra-pass barriers remain explicit.

`Recorder` contains GPU bindings, profiler state, uploaded overlay spans, and a draw tally. It has no packet, settings, scene pools, history, or shadow cache.

## Counters and commit

`passes_counters` sums the planned counters from the built list. Debug recording compares its own emitted draw and indirect-call tallies with them (`frame_record`). For GPU-cull draws, planned counters report candidates rather than post-cull visibility. The cull validator independently rebuilds its expected batching and reads the submitted frame's slot.

After submission, `frame_commit` applies shadow invalidations and rendered views, acknowledges this slot's transform uploads, clears consumed scene changes, and publishes the counters. A skipped frame does none of these. Dirty bits for other slots remain set until those slots submit.

## Checks

Run `just frame-checks` for CPU fixtures covering packing, capacity fallback, dirty-slot commits, overlay clipping and counters, settings, pass presence and order, the frame's CPU/GPU cull choice, cull pass ranges and budget fallback, bloom/tonemap sizes and levels, declared pass uses, and resize dimensions. `scripts/verify_prepared_frames.py` builds isolated before and after sources through `just`, then compares exact pixels and clean debug logs. It requires Pillow, a working Vulkan display, and the vendored dependencies. Its replay changes settings, moves a caster during a skipped frame, resizes the window, and renders lines, text, and a clipped debug view. It never edits this checkout's scene selection.

# Prepared frame

The game owns `RenderSettings` and builds an `Overlay` each tick. `FramePacket` borrows the overlay and scene draws until `engine_render` returns. Game temporary storage releases them at the end of the tick, including when rendering skips.

`engine_render` synchronizes draw history before acquiring a frame. Acquisition and target resize precede preparation. Shader reload invalidates the shadow cache before planning, and shadow caster sync updates retained bounds before filtering.

`frame_prepare` reads explicit `PrepareInput` and produces a temporary `PreparedFrame`. It chooses passes, filters shadow views, chooses CPU or GPU culling, assigns instance and indirect spans, and plans uploads and counters. It does not change the history, shadow cache, or GPU state. Odin does not enforce read-only pointers; callers must preserve this contract.

```odin
frame_prepare :: proc(input: PrepareInput) -> PreparedFrame
frame_upload :: proc(r: ^Recorder, f: ^PreparedFrame)
frame_record :: proc(r: ^Recorder, f: ^PreparedFrame)
frame_commit :: proc(engine: ^Engine, f: ^PreparedFrame, packet: ^FramePacket)
```

`LayoutBuilder` owns the shared instance and indirect budgets. Packing order remains 2D shadow views, cube shadow views, main opaque draws, then transparent draws. `src/graphics/frame_layout.odin` owns building, uploading and encoding these spans. GPU cull outputs use separate buffers and capacities. Indirect overflow produces direct draws; instance overflow drops the remaining runs in that allocation request.

`Recorder` contains GPU bindings, profiler state, uploaded overlay spans, and a draw tally. It has no packet, settings, scene pools, history, or shadow cache. Each pass keeps its preparation and encoding logic together. `PassSpec` retains image uses and fixed execution order. Prepared pass presence determines enablement. Intra-pass barriers remain explicit.

After submission, `frame_commit` applies shadow invalidations and rendered views, acknowledges this slot's transform uploads, clears consumed scene changes, and publishes prepared counters. A skipped frame does none of these. Dirty bits for other slots remain set until those slots submit.

Debug recording compares its emitted draw and indirect-call tallies with planned counters. For GPU-cull draws, planned counters report candidates rather than post-cull visibility. The cull validator independently rebuilds its expected batching and reads the submitted frame's slot.

Run `just frame-checks` for CPU fixtures covering packing, capacity fallback, dirty-slot commits, overlay clipping, settings, and resize dimensions. `scripts/verify_prepared_frames.py` builds isolated before and after sources through `just`, then compares exact pixels and clean debug logs. It requires Pillow, a working Vulkan display, and the vendored dependencies. The script's default baseline is the commit before this refactor; `--baseline` selects another commit. Its replay changes settings, moves a caster during a skipped frame, resizes the window, and renders lines, text, and a clipped debug view. It never edits this checkout's scene selection.

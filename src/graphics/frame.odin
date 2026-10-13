package graphics

import "backend"

// Target sizes frame_prepare plans against. The bindless slots and the render targets stay in the engine.
TargetInfo :: struct {
	extent:       backend.Extent2D,
	bloom_extent: backend.Extent2D,
	bloom_mips:   u32,
}

// Device addresses of the per-slot light and cluster buffers. They are written into SceneData, so prepare needs them.
UploadAddresses :: struct {
	point_lights:    backend.GPUPtr(GpuPointLight),
	spot_lights:     backend.GPUPtr(GpuSpotLight),
	cluster_headers: backend.GPUPtr(ClusterHeader),
	cluster_indices: backend.GPUPtr(u32),
}

// Everything frame_prepare reads. Pointers are read-only by contract; Odin can't enforce it.
PrepareInput :: struct {
	packet:           ^FramePacket,
	history:          ^DrawHistory,
	casters:          ^ShadowCasters,
	cache:            ^ShadowCache,
	models:           ^Pool(Model),
	materials:        ^Pool(Material),
	sky:              CubeIndex,
	targets:          TargetInfo,
	addresses:        UploadAddresses,
	slot:             int,
	frame_count:      u32,
	budget:           FrameBudget,
	cull_readback:    bool,
	cluster_validate: bool,
}

// Buffer handles and device addresses that the geometry draws bind to.
GeometryBuffers :: struct {
	index:     backend.Buffer(u32),
	vertices:  backend.GPUPtr(Vertex),
	materials: backend.GPUPtr(GpuMaterial),
}

// Draw and indirect calls that record emitted. Debug builds assert them against FrameCounters.
RecordTally :: struct {
	draw_calls:     u32,
	indirect_calls: u32,
}

// GPU handles only: no packet, settings, pools, history or shadow cache. Built by recorder_make.
Recorder :: struct {
	ctx:                  ^backend.Context,
	cmd:                  backend.CommandBuffer,
	slot:                 int,
	frame:                ^FrameData,
	prev_frame:           ^FrameData,
	targets:              ^RenderTargets,
	atlas_2d, atlas_cube: backend.Image,
	pipelines:            ^PipelineRegistry,
	geometry:             GeometryBuffers,
	profiler:             ^GpuProfiler,
	overlay:              UploadedOverlay,
	tally:                RecordTally,
}

// A nil Maybe means the pass is skipped this frame. This is the single source of pass enablement:
// pass_enabled reads these fields.
PassPreps :: struct {
	particles:    Maybe(ParticlesPrep),
	shadow_2d:    Maybe(ShadowPassPrep),
	shadow_point: Maybe(ShadowPassPrep),
	clusters:     Maybe(ClustersPrep),
	main:         MainPrep,
	bloom:        BloomPrep,
	tonemap:      TonemapPrep,
	overlay:      PreparedOverlay,
}

// Host writes for this slot, already in the byte layout their buffers expect.
FrameUploads :: struct {
	scene:        SceneData,
	point_lights: []GpuPointLight,
	spot_lights:  []GpuSpotLight,
	transforms:   []TransformWrite,
	layout:       FrameLayout,
	cull:         Maybe(CullUpload),
}

// Debug decisions that record and the post-submit checks read.
FrameDebug :: struct {
	cull_readback:           bool,
	cluster_overflow_report: bool,
	cluster_validate:        bool,
}

// The whole frame as data. Temp-allocated, so it lives until engine_render returns.
PreparedFrame :: struct {
	slot:        int,
	frame_count: u32,
	targets:     TargetInfo,
	passes:      PassPreps,
	uploads:     FrameUploads,
	shadow_plan: ShadowPlan,
	counters:    FrameCounters,
	debug:       FrameDebug,
}

rec_pipeline :: #force_inline proc(r: ^Recorder, kind: PipelineKind) -> backend.Pipeline {
	return r.pipelines.pipelines[kind]
}

rec_scene_data :: #force_inline proc(r: ^Recorder) -> backend.GPUPtr(SceneData) {
	return backend.buffer_address(r.ctx, r.frame.scene_data_buffer)
}

// Pure: reads input and writes only its return value. The call order fixes the layout's allocation
// order (2D shadow views, cube shadow views, main opaque, transparent), so it must not change.
frame_prepare :: proc(input: PrepareInput) -> PreparedFrame {
	f := PreparedFrame {
		slot        = input.slot,
		frame_count = input.frame_count,
		targets     = input.targets,
	}
	layout := layout_builder_make(input.budget)
	f.shadow_plan, f.passes.shadow_2d, f.passes.shadow_point = shadow_prepare(input, &layout)
	f.uploads.scene, f.uploads.point_lights, f.uploads.spot_lights = scene_data_build(input, &f.shadow_plan)
	settings := input.packet.settings
	f.passes.clusters = clusters_prepare(
		input.packet.camera,
		settings.clustered_lighting || settings.cluster_heatmap || input.cluster_validate,
	)
	f.passes.particles = particles_prepare(input.packet)
	f.passes.main, f.uploads.cull = main_prepare(input, &layout)
	f.passes.bloom = bloom_prepare(input.targets, input.packet.camera.post)
	f.passes.tonemap = tonemap_prepare(input.targets, input.packet.camera.post, f.passes.bloom)
	f.passes.overlay = overlay_prepare(input.packet.overlay, settings, input.targets.extent)
	f.uploads.transforms = transform_writes(input.history, input.slot)
	f.uploads.layout = layout_finish(&layout)
	f.counters = frame_counters(&f)
	f.debug.cull_readback = input.cull_readback && f.uploads.cull != nil
	f.debug.cluster_validate = input.cluster_validate
	when ODIN_DEBUG {
		f.debug.cluster_overflow_report = input.frame_count % 120 == 0 && f.passes.clusters != nil
	}
	return f
}

// Sums the pass preps into the counters record must match. Runs after every pass is prepared.
@(private = "file")
frame_counters :: proc(f: ^PreparedFrame) -> FrameCounters {
	counters: FrameCounters
	total := f.passes.main.counters
	if p, ok := f.passes.shadow_2d.(ShadowPassPrep); ok {
		draw_counters_add(&total, p.counters)
		counters.shadow_views += u32(len(p.views))
	}
	if p, ok := f.passes.shadow_point.(ShadowPassPrep); ok {
		draw_counters_add(&total, p.counters)
		counters.shadow_views += u32(len(p.views))
	}
	counters.draw_calls = total.draw_calls + f.passes.overlay.draw_calls
	counters.dropped_lines = f.passes.overlay.dropped_lines
	counters.dropped_ui = f.passes.overlay.dropped_ui
	counters.dropped_debug_views = f.passes.overlay.dropped_debug_views
	counters.indirect_calls = total.indirect_calls
	counters.triangles = total.triangles
	counters.candidate_instances = total.candidate_instances
	counters.candidate_triangles = total.candidate_triangles
	counters.draws_visible = f.passes.main.draws_visible
	counters.meshes_culled = f.passes.main.meshes_culled
	counters.shadow_views_cached = f.shadow_plan.views_cached
	return counters
}

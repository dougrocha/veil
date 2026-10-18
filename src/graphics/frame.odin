package graphics

import "backend"

// Target sizes the frame build plans against. The bindless slots and the render targets stay in the engine.
TargetInfo :: struct {
	extent:       backend.Extent2D,
	bloom_extent: backend.Extent2D,
	bloom_mips:   u32,
}

// Device addresses of the per-slot light and cluster buffers. They are written into SceneData, so the build needs them.
UploadAddresses :: struct {
	point_lights:    backend.GPUPtr(GpuPointLight),
	spot_lights:     backend.GPUPtr(GpuSpotLight),
	cluster_headers: backend.GPUPtr(ClusterHeader),
	cluster_indices: backend.GPUPtr(u32),
}

// Everything frame_build reads. Pointers are read-only by contract; Odin can't enforce it.
FrameInput :: struct {
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

// Host writes for this slot, already in the byte layout their buffers expect.
// These are the frame-wide outputs that no single pass owns (every pass reads the scene data, the
// layout spans back several passes), so they ride beside the pass list instead of inside a pass.
FrameUploads :: struct {
	scene:        SceneData,
	point_lights: []GpuPointLight,
	spot_lights:  []GpuSpotLight,
	transforms:   []TransformWrite,
	layout:       FrameLayout,
}

rec_pipeline :: #force_inline proc(r: ^Recorder, kind: PipelineKind) -> backend.Pipeline {
	return r.pipelines.pipelines[kind]
}

rec_scene_data :: #force_inline proc(r: ^Recorder) -> backend.GPUPtr(SceneData) {
	return backend.buffer_address(r.ctx, r.frame.scene_data_buffer)
}

// Pure: reads input and writes only its return values. Passes are appended in execution order; a
// skipped pass is not appended. The call order fixes the layout's allocation order (2D shadow views,
// cube shadow views, main opaque, transparent), so it must not change. shadow_plan is the third
// frame-wide output beside the list and the uploads: commit reads it after submission.
frame_build :: proc(input: FrameInput) -> (passes: []Pass, uploads: FrameUploads, shadow_plan: ShadowPlan) {
	list := make([dynamic]Pass, context.temp_allocator)
	settings := input.packet.settings
	layout := layout_builder_make(input.budget)
	if p, ok := particles_pass_build(input.packet); ok do append(&list, p)
	shadow_plan = shadow_passes_build(input, &layout, &list)
	uploads.scene, uploads.point_lights, uploads.spot_lights = scene_data_build(input, &shadow_plan)
	clusters_enabled := settings.clustered_lighting || settings.cluster_heatmap || input.cluster_validate
	if p, ok := clusters_pass_build(input.packet.camera, clusters_enabled); ok do append(&list, p)
	append(&list, main_pass_build(input, &layout))
	bloom, tonemap := post_passes_build(input.targets, input.packet.camera.post)
	append(&list, bloom, tonemap)
	append(&list, overlay_pass_build(input.packet.overlay, settings, input.targets.extent))
	uploads.transforms = transform_writes(input.history, input.slot)
	uploads.layout = layout_finish(&layout)
	return list[:], uploads, shadow_plan
}

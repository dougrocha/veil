package graphics

import "backend"

import vk "vendor:vulkan"

MAX_LINE_VERTICES :: 65536

LineVertex :: struct {
	position: Vec3,
	color:    Vec4,
}

LinePushConstants :: struct {
	scene_data:    GPUPtr(SceneData),
	vertex_buffer: GPUPtr(LineVertex),
}

LineRenderer :: struct {
	vertices: [dynamic]LineVertex,
	buffers:  [MAX_FRAMES_IN_FLIGHT]GpuBuffer(LineVertex),
}

line_renderer_create :: proc(engine: ^Engine) -> (ok: bool) {
	lr := &engine.line_renderer

	config := new(GraphicsPipelineConfig)
	backend.pipeline_default_config(config)
	config.rasterization.cullMode = {}
	config.input_assembly.topology = .LINE_LIST
	config.push_constant_range = {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = size_of(LinePushConstants),
	}

	shader_handle := shader_load(engine, "line", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	stages := shader_default_stages(engine, shader_handle)
	pipeline_register(engine, .Line_List, shader_handle, config, stages[:])

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		lr.buffers[i] = backend.buffer_create(LineVertex, &engine.vk_ctx, MAX_LINE_VERTICES, .MappedStorage)
	}
	reserve(&lr.vertices, MAX_LINE_VERTICES)

	return true
}

line_renderer_destroy :: proc(engine: ^Engine, lr: ^LineRenderer) {
	delete(lr.vertices)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		backend.buffer_destroy(&engine.vk_ctx, lr.buffers[i])
	}
}

line_renderer_push :: proc(ln: ^LineRenderer, from, to: Vec3, color: Vec4) {
	unimplemented()
}

line_renderer_flush :: proc(ln: ^LineRenderer, cmd: vk.CommandBuffer) {
	unimplemented()
}


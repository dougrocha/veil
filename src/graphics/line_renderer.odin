package graphics

import "core:mem"

import "backend"

MAX_LINE_VERTICES :: 65536

LINE_THICKNESS_PX :: 3.0

LineVertex :: struct {
	position: Vec3,
	_pad0:    f32,
	color:    Vec4,
}

LinePushConstants :: struct {
	scene_data:    backend.GPUPtr(SceneData),
	vertex_buffer: backend.GPUPtr(LineVertex),
	screen_size:   Vec2,
	thickness:     f32,
}

LineBatch :: struct {
	vertices: [dynamic]LineVertex,
	buffers:  [backend.MAX_FRAMES_IN_FLIGHT]backend.GpuBuffer(LineVertex),
}

LineRenderer :: struct {
	tested:  LineBatch,
	sector:  LineBatch,
	overlay: LineBatch,
}

line_renderer_create :: proc(engine: ^Engine) -> (ok: bool) {
	lr := &engine.line_renderer

	config := backend.pipeline_default_config()
	backend.pipeline_config_set_no_cull(&config)
	backend.pipeline_config_set_msaa(&config, &engine.vk_ctx)
	backend.pipeline_config_set_push_constant(&config, size_of(LinePushConstants), {.Vertex, .Fragment})

	shader_handle := shader_load(engine, "line", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	pipeline_register(engine, .Debug_Line, shader_handle, config)

	// overlay variant: same shader, no depth test (drawn last, on top of everything)
	overlay_config := config
	backend.pipeline_config_disable_depth(&overlay_config)
	backend.pipeline_config_set_blend(&overlay_config, .Alpha)
	pipeline_register(engine, .Debug_Line_Overlay, shader_handle, overlay_config)
	sector_shader := shader_load(engine, "sector", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	pipeline_register(engine, .Debug_Sector, sector_shader, overlay_config)

	batch_create(engine, &lr.tested)
	batch_create(engine, &lr.sector)
	batch_create(engine, &lr.overlay)

	return true
}

line_renderer_destroy :: proc(engine: ^Engine) {
	lr := &engine.line_renderer
	batch_destroy(engine, &lr.tested)
	batch_destroy(engine, &lr.sector)
	batch_destroy(engine, &lr.overlay)
}

line_renderer_push :: proc(lr: ^LineRenderer, from, to: Vec3, color: Vec4, overlay := false) {
	batch := &lr.overlay if overlay else &lr.tested

	from := LineVertex {
		position = from,
		color    = color,
	}

	to := LineVertex {
		position = to,
		color    = color,
	}

	append(&batch.vertices, from)
	append(&batch.vertices, to)
}

line_renderer_push_sector_triangle :: proc(lr: ^LineRenderer, a, b, c: Vec3, color: Vec4) {
	append(&lr.sector.vertices,
		LineVertex{position = a, color = color},
		LineVertex{position = b, color = color},
		LineVertex{position = c, color = color},
	)
}

line_renderer_clear :: proc(engine: ^Engine) {
	lr := &engine.line_renderer
	clear(&lr.tested.vertices)
	clear(&lr.sector.vertices)
	clear(&lr.overlay.vertices)
}

line_renderer_flush :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	lr := &engine.line_renderer
	flush_batch(engine, cmd, &lr.tested, .Debug_Line)
	flush_batch(engine, cmd, &lr.sector, .Debug_Sector, 1)
	flush_batch(engine, cmd, &lr.overlay, .Debug_Line_Overlay)
}

@(private = "file")
batch_create :: proc(engine: ^Engine, batch: ^LineBatch) {
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		batch.buffers[i] = backend.buffer_create(LineVertex, &engine.vk_ctx, MAX_LINE_VERTICES, .MappedStorage)
	}
	reserve(&batch.vertices, MAX_LINE_VERTICES)
}

@(private = "file")
batch_destroy :: proc(engine: ^Engine, batch: ^LineBatch) {
	delete(batch.vertices)
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		backend.buffer_destroy(&engine.vk_ctx, batch.buffers[i])
	}
}

@(private = "file")
flush_batch :: proc(engine: ^Engine, cmd: backend.RenderEncoder, batch: ^LineBatch, kind: PipelineKind, vertex_multiplier: u32 = 3) {
	if len(batch.vertices) == 0 do return
	assert(len(batch.vertices) <= MAX_LINE_VERTICES)

	frame_res_index := current_frame_res_index(engine)
	buffer := &batch.buffers[frame_res_index]
	mem.copy(backend.buffer_mapped_ptr(buffer^), raw_data(batch.vertices), len(batch.vertices) * size_of(LineVertex))

	pipeline := get_pipeline(&engine.pipeline_registry, kind)
	pc := LinePushConstants {
		scene_data    = current_frame_data(engine).scene_data_buffer.ptr,
		vertex_buffer = buffer.ptr,
		screen_size   = {f32(engine.swapchain.extent.width), f32(engine.swapchain.extent.height)},
		thickness     = LINE_THICKNESS_PX,
	}
	backend.pipeline_bind(cmd, pipeline)
	// Both buffers are reached through GPU addresses in the shader, so Metal needs
	// them made resident explicitly — the encoder can't see them as bound arguments.
	backend.cmd_use_buffer(cmd, current_frame_data(engine).scene_data_buffer)
	backend.cmd_use_buffer(cmd, buffer^)
	backend.pipeline_push(cmd, pipeline, {.Vertex, .Fragment}, &pc)
	// Line segments expand to six vertices; sector triangles use their three stored vertices.
	backend.cmd_draw(cmd, u32(len(batch.vertices)) * vertex_multiplier)

	clear(&batch.vertices)
}

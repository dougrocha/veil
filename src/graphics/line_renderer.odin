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
	buffers:  [backend.MAX_FRAMES_IN_FLIGHT]backend.Buffer(LineVertex),
}

LineRenderer :: struct {
	tested:  LineBatch,
	sector:  LineBatch,
	overlay: LineBatch,
}

line_renderer_create :: proc(engine: ^Engine) -> (ok: bool) {
	lr := &engine.line_renderer

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
	append(
		&lr.sector.vertices,
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
		batch.buffers[i] = backend.buffer_create(LineVertex, &engine.vk_ctx, MAX_LINE_VERTICES, {.Storage}, .Shared)
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
flush_batch :: proc(
	engine: ^Engine,
	cmd: backend.RenderEncoder,
	batch: ^LineBatch,
	kind: GraphicsPipelineKind,
	vertex_multiplier: u32 = 3,
) {
	if len(batch.vertices) == 0 do return
	assert(len(batch.vertices) <= MAX_LINE_VERTICES)

	frame_res_index := backend.frame_slot(&engine.vk_ctx)
	buffer := &batch.buffers[frame_res_index]
	mem.copy(
		backend.buffer_contents(&engine.vk_ctx, buffer^),
		raw_data(batch.vertices),
		len(batch.vertices) * size_of(LineVertex),
	)

	pipeline := graphics_pipeline(engine, kind)
	pc := LinePushConstants {
		scene_data    = backend.buffer_address(&engine.vk_ctx, current_frame_data(engine).scene_data_buffer),
		vertex_buffer = backend.buffer_address(&engine.vk_ctx, buffer^),
		screen_size   = render_viewport(engine),
		thickness     = LINE_THICKNESS_PX,
	}
	backend.pipeline_bind(cmd, pipeline)
	backend.pipeline_push(cmd, &pc)
	// Line segments expand to six vertices; sector triangles use their three stored vertices.
	backend.cmd_draw(cmd, u32(len(batch.vertices)) * vertex_multiplier)
	stats_count_draw(engine)

	clear(&batch.vertices)
}

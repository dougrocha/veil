package graphics

import "backend"

@(shader_shared)
LineVertex :: struct #max_field_align(16) {
	position: Vec3,
	_pad0:    f32,
	color:    Vec4,
}

// Shared by line.slang and sector.slang.
@(shader_shared)
LinePushConstants :: struct #max_field_align(16) {
	scene_data:    backend.GPUPtr(SceneData),
	vertex_buffer: backend.GPUPtr(LineVertex),
	screen_size:   Vec2,
	thickness:     f32,
}

MAX_LINE_VERTICES :: 65536

LINE_THICKNESS_PX :: 3.0

LineRenderer :: struct {
	tested:  TransientBatch(LineVertex),
	sector:  TransientBatch(LineVertex),
	overlay: TransientBatch(LineVertex),
}

line_renderer_create :: proc(engine: ^Engine) -> (ok: bool) {
	lr := &engine.line_renderer

	transient_batch_create(&engine.vk_ctx, &lr.tested, MAX_LINE_VERTICES)
	transient_batch_create(&engine.vk_ctx, &lr.sector, MAX_LINE_VERTICES)
	transient_batch_create(&engine.vk_ctx, &lr.overlay, MAX_LINE_VERTICES)

	return true
}

line_renderer_destroy :: proc(engine: ^Engine) {
	lr := &engine.line_renderer
	transient_batch_destroy(&engine.vk_ctx, &lr.tested)
	transient_batch_destroy(&engine.vk_ctx, &lr.sector)
	transient_batch_destroy(&engine.vk_ctx, &lr.overlay)
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

	append(&batch.items, from)
	append(&batch.items, to)
}

line_renderer_push_sector_triangle :: proc(lr: ^LineRenderer, a, b, c: Vec3, color: Vec4) {
	append(
		&lr.sector.items,
		LineVertex{position = a, color = color},
		LineVertex{position = b, color = color},
		LineVertex{position = c, color = color},
	)
}

line_renderer_clear :: proc(engine: ^Engine) {
	lr := &engine.line_renderer
	clear(&lr.tested.items)
	clear(&lr.sector.items)
	clear(&lr.overlay.items)
}

line_renderer_flush :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	lr := &engine.line_renderer
	flush_batch(engine, cmd, &lr.tested, .Debug_Line)
	flush_batch(engine, cmd, &lr.sector, .Debug_Sector, 1)
	flush_batch(engine, cmd, &lr.overlay, .Debug_Line_Overlay)
}

@(private = "file")
flush_batch :: proc(
	engine: ^Engine,
	cmd: backend.RenderEncoder,
	batch: ^TransientBatch(LineVertex),
	kind: GraphicsPipelineKind,
	vertex_multiplier: u32 = 3,
) {
	vertices, count := transient_batch_upload(&engine.vk_ctx, batch)
	if count == 0 do return

	pipeline := graphics_pipeline(engine, kind)
	pc := LinePushConstants {
		scene_data    = backend.buffer_address(&engine.vk_ctx, current_frame_data(engine).scene_data_buffer),
		vertex_buffer = vertices,
		screen_size   = render_viewport(engine),
		thickness     = LINE_THICKNESS_PX,
	}
	backend.pipeline_bind(cmd, pipeline)
	backend.pipeline_push(cmd, &pc)
	// Line segments expand to six vertices; sector triangles use their three stored vertices.
	backend.cmd_draw(cmd, count * vertex_multiplier)
	stats_count_draw(engine)
}

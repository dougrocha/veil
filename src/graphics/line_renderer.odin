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

// Per-slot vertex buffers per LineBatch.
LineRenderer :: struct {
	buffers: [LineBatch][backend.MAX_FRAMES_IN_FLIGHT]backend.Buffer(LineVertex),
}

line_renderer_create :: proc(engine: ^Engine) -> bool {
	for &batch in engine.line_renderer.buffers {
		for &buffer in batch {
			buffer = backend.buffer_create(LineVertex, &engine.vk_ctx, MAX_LINE_VERTICES, {.Storage}, .Shared)
		}
	}
	return true
}

line_renderer_destroy :: proc(engine: ^Engine) {
	for batch in engine.line_renderer.buffers {
		for buffer in batch do backend.buffer_destroy(&engine.vk_ctx, buffer)
	}
}

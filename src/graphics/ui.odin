package graphics

import "backend"

@(shader_shared)
UIVertex :: struct #max_field_align(16) {
	position: Vec2, // screen-space pixels, top-left origin, y-down
	uv:       Vec2,
	color:    [4]u8, // RGBA8, a packed uint in the shader
	_pad0:    u32,
}

@(shader_shared)
UIPushConstants :: struct #max_field_align(16) {
	vertex_buffer: backend.GPUPtr(UIVertex),
	screen_size:   Vec2,
	atlas_texture: TextureIndex, // bindless index into the texture descriptor array
}

MAX_UI_VERTICES :: 65536

// One set of per-slot vertex buffers per font atlas, keyed by the atlas's bindless texture index,
// created on first use.
UIRenderer :: struct {
	buffers: map[u32][backend.MAX_FRAMES_IN_FLIGHT]backend.Buffer(UIVertex),
}

ui_renderer_create :: proc(engine: ^Engine) {
	engine.ui_renderer.buffers = make(map[u32][backend.MAX_FRAMES_IN_FLIGHT]backend.Buffer(UIVertex))
}

ui_renderer_destroy :: proc(engine: ^Engine) {
	for _, buffers in engine.ui_renderer.buffers {
		for buffer in buffers do backend.buffer_destroy(&engine.vk_ctx, buffer)
	}
	delete(engine.ui_renderer.buffers)
}

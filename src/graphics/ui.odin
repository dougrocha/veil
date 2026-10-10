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

// One batch per font atlas in use this frame, keyed by the atlas's
// bindless texture index — lets ui_draw_text mix multiple fonts/sizes
// per frame without one clobbering another's vertices.
UIRenderer :: struct {
	batches: map[u32]TransientBatch(UIVertex),
}

ui_renderer_create :: proc(engine: ^Engine) {
	engine.ui_renderer.batches = make(map[u32]TransientBatch(UIVertex))
}

ui_renderer_destroy :: proc(engine: ^Engine) {
	ur := &engine.ui_renderer
	for _, &batch in ur.batches {
		transient_batch_destroy(&engine.vk_ctx, &batch)
	}
	delete(ur.batches)
}

ui_renderer_clear :: proc(engine: ^Engine) {
	for _, &batch in engine.ui_renderer.batches {
		transient_batch_clear(&batch)
	}
}

// Returns the batch for `atlas_texture`, lazily creating its GPU buffers on
// first use. Called by ui_draw_text, not meant to be called directly.
ui_renderer_batch_for :: proc(engine: ^Engine, atlas_texture: u32) -> ^TransientBatch(UIVertex) {
	ur := &engine.ui_renderer
	if atlas_texture not_in ur.batches {
		batch: TransientBatch(UIVertex)
		transient_batch_create(&engine.vk_ctx, &batch, MAX_UI_VERTICES)
		ur.batches[atlas_texture] = batch
	}
	return &ur.batches[atlas_texture]
}

ui_renderer_flush :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	ur := &engine.ui_renderer
	pipeline := pipeline_get(engine, .UI)

	for atlas_texture, &batch in ur.batches {
		vertices, count := transient_batch_upload(&engine.vk_ctx, &batch)
		if count == 0 do continue

		pc := UIPushConstants {
			vertex_buffer = vertices,
			screen_size   = render_viewport(engine),
			atlas_texture = TextureIndex(atlas_texture),
		}
		backend.pipeline_bind(cmd, pipeline)
		backend.pipeline_push(cmd, &pc)
		backend.cmd_draw(cmd, count)
		stats_count_draw(engine)
	}
}

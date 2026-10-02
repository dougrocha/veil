package graphics

import "core:mem"

import "backend"

MAX_UI_VERTICES :: 65536

UI_Vertex :: struct {
	position: Vec2,
	uv:       Vec2,
	color:    [4]u8,
	_pad0:    u32,
}

UI_Batch :: struct {
	vertices: [dynamic]UI_Vertex,
	buffers:  [backend.MAX_FRAMES_IN_FLIGHT]backend.GpuBuffer(UI_Vertex),
}

// One UI_Batch per font atlas in use this frame, keyed by the atlas's
// bindless texture index — lets ui_draw_text mix multiple fonts/sizes
// per frame without one clobbering another's vertices.
UIRenderer :: struct {
	batches: map[u32]UI_Batch,
}

ui_renderer_create :: proc(engine: ^Engine) {
	engine.ui_renderer.batches = make(map[u32]UI_Batch)
}

ui_renderer_destroy :: proc(engine: ^Engine) {
	ur := &engine.ui_renderer
	for _, &batch in ur.batches {
		batch_destroy(engine, &batch)
	}
	delete(ur.batches)
}

ui_renderer_clear :: proc(engine: ^Engine) {
	for _, &batch in engine.ui_renderer.batches {
		clear(&batch.vertices)
	}
}

// Returns the batch for `atlas_texture`, lazily creating its GPU buffers on
// first use. Called by ui_draw_text, not meant to be called directly.
ui_renderer_batch_for :: proc(engine: ^Engine, atlas_texture: u32) -> ^UI_Batch {
	ur := &engine.ui_renderer
	if atlas_texture not_in ur.batches {
		batch: UI_Batch
		batch_create(engine, &batch)
		ur.batches[atlas_texture] = batch
	}
	return &ur.batches[atlas_texture]
}

ui_renderer_flush :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	ur := &engine.ui_renderer
	pipeline := get_pipeline(&engine.pipeline_registry, .UI)
	frame_res_index := current_frame_res_index(engine)

	for atlas_texture, &batch in ur.batches {
		if len(batch.vertices) == 0 do continue
		assert(len(batch.vertices) <= MAX_UI_VERTICES)

		buffer := &batch.buffers[frame_res_index]
		mem.copy(
			backend.buffer_mapped_ptr(buffer^),
			raw_data(batch.vertices),
			len(batch.vertices) * size_of(UI_Vertex),
		)

		pc := UIPushConstants {
			vertex_buffer = buffer.ptr,
			screen_size   = {f32(engine.swapchain.extent.width), f32(engine.swapchain.extent.height)},
			atlas_texture = atlas_texture,
		}
		backend.pipeline_bind(cmd, pipeline, {engine.texture_system.descriptor.sets[frame_res_index]})
		backend.pipeline_push(cmd, pipeline, {.Vertex, .Fragment}, &pc, index = 1)
		backend.cmd_draw(cmd, u32(len(batch.vertices)))
		stats_count_draw(engine)

		clear(&batch.vertices)
	}
}

@(private = "file")
batch_create :: proc(engine: ^Engine, batch: ^UI_Batch) {
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		batch.buffers[i] = backend.buffer_create(UI_Vertex, &engine.vk_ctx, MAX_UI_VERTICES, .MappedStorage)
	}
	reserve(&batch.vertices, MAX_UI_VERTICES)
}

@(private = "file")
batch_destroy :: proc(engine: ^Engine, batch: ^UI_Batch) {
	delete(batch.vertices)
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		backend.buffer_destroy(&engine.vk_ctx, batch.buffers[i])
	}
}

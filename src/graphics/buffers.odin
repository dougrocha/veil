package graphics

import "core:math/rand"

import "backend"

FrameData :: struct {
	scene_data_buffer: backend.Buffer(SceneData),
	particle_buffer:   backend.Buffer(Particle),
	transforms_buffer: backend.Buffer(GpuTransform),
}

frame_data_create :: proc(engine: ^Engine) {
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		engine.frame_data[i].scene_data_buffer = backend.buffer_create(
			SceneData,
			&engine.vk_ctx,
			1,
			{.Uniform},
			.Shared,
		)
		engine.frame_data[i].transforms_buffer = backend.buffer_create(
			GpuTransform,
			&engine.vk_ctx,
			MAX_MODEL_INSTANCES,
			{.Storage},
			.Shared,
		)
		engine.frame_data[i].particle_buffer = create_particle_buffer(
			&engine.vk_ctx,
			Rect2D{extent = {u32(engine.swapchain.extent.width), u32(engine.swapchain.extent.height)}},
		)
	}
}

frame_data_destroy :: proc(engine: ^Engine) {
	for &res in engine.frame_data {
		backend.buffer_destroy(&engine.vk_ctx, res.scene_data_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.particle_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.transforms_buffer)
	}
}

// TODO: This code is half engine/game code, needs ot be looked at
create_particle_buffer :: proc(ctx: ^backend.Context, extent: Rect2D) -> backend.Buffer(Particle) {
	particles := make([]Particle, PARTICLE_COUNT, context.temp_allocator)

	for &p in particles {
		x := rand.float32() * 20.0 - 10.0
		y := rand.float32() * 15.0
		z := rand.float32() * 20.0 - 10.0
		p.position = {x, y, z, 1.0}
		p.velocity = {0, -(rand.float32() * 4.0 + 3.0), 0, 0}
		brightness := rand.float32() * 0.3 + 0.7
		p.color = {brightness * 0.6, brightness * 0.8, brightness, 0.8}
	}

	return backend.buffer_upload(ctx, particles, {.Storage, .Vertex})
}

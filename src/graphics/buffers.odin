package graphics

import "core:math/rand"

import "backend"

@(shader_shared)
Particle :: struct #max_field_align(16) {
	position: Vec4,
	velocity: Vec4,
	color:    Vec4,
}

@(shader_shared)
ParticlePushConstants :: struct #max_field_align(16) {
	scene_data:    backend.GPUPtr(SceneData),
	particles_in:  backend.GPUPtr(Particle),
	particles_out: backend.GPUPtr(Particle),
	delta_time:    f32,
}

FrameData :: struct {
	scene_data_buffer:   backend.Buffer(SceneData),
	point_lights_buffer: backend.Buffer(GpuPointLight),
	spot_lights_buffer:  backend.Buffer(GpuSpotLight),
	clusters:            ClusterBuffers,
	particle_buffer:     backend.Buffer(Particle),
	transforms_buffer:   backend.Buffer(GpuTransform),
	instance_ids_buffer: backend.Buffer(u32),
	instance_id_count:   u32, // ids written this frame
	transforms_dirty:    [MAX_DRAWS / 64]u64, // draw ids changed since transforms_buffer was written
}

#assert(MAX_DRAWS % 64 == 0)

frame_data_create :: proc(engine: ^Engine) {
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		engine.frame_data[i].scene_data_buffer = backend.buffer_create(
			SceneData,
			&engine.vk_ctx,
			1,
			{.Uniform},
			.Shared,
		)
		engine.frame_data[i].point_lights_buffer = backend.buffer_create(
			GpuPointLight,
			&engine.vk_ctx,
			MAX_POINT_LIGHTS,
			{.Storage},
			.Shared,
		)
		engine.frame_data[i].spot_lights_buffer = backend.buffer_create(
			GpuSpotLight,
			&engine.vk_ctx,
			MAX_SPOT_LIGHTS,
			{.Storage},
			.Shared,
		)
		engine.frame_data[i].transforms_buffer = backend.buffer_create(
			GpuTransform,
			&engine.vk_ctx,
			MAX_DRAWS,
			{.Storage},
			.Shared,
		)
		engine.frame_data[i].instance_ids_buffer = backend.buffer_create(
			u32,
			&engine.vk_ctx,
			MAX_INSTANCE_IDS,
			{.Storage},
			.Shared,
		)
		engine.frame_data[i].particle_buffer = create_particle_buffer(&engine.vk_ctx)
	}
	cluster_buffers_create(engine)
}

frame_data_destroy :: proc(engine: ^Engine) {
	for &res in engine.frame_data {
		backend.buffer_destroy(&engine.vk_ctx, res.scene_data_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.point_lights_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.spot_lights_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.particle_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.transforms_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.instance_ids_buffer)
	}
	cluster_buffers_destroy(engine)
}

// TODO: This code is half engine/game code, needs ot be looked at
create_particle_buffer :: proc(ctx: ^backend.Context) -> backend.Buffer(Particle) {
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

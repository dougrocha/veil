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
	scene_data_buffer:      backend.Buffer(SceneData),
	point_lights_buffer:    backend.Buffer(GpuPointLight),
	spot_lights_buffer:     backend.Buffer(GpuSpotLight),
	clusters:               ClusterBuffers,
	particle_buffer:        backend.Buffer(Particle),
	transforms_buffer:      backend.Buffer(GpuTransform),
	instance_ids_buffer:    backend.Buffer(u32),
	indirect_buffer:        backend.Buffer(DrawIndexedIndirectCommand),
	cull_candidates:        backend.Buffer(GpuCullCandidate),
	cull_runs:              backend.Buffer(GpuCullRun),
	cull_output_ids:        backend.Buffer(u32),
	cull_commands:          backend.Buffer(DrawIndexedIndirectCommand),
	cull_planes:            backend.Buffer(Vec4),
	cull_readback_ids:      backend.Buffer(u32),
	cull_readback_commands: backend.Buffer(DrawIndexedIndirectCommand),
	// Commands in cull_readback_commands from this slot's last submitted frame; 0 when it did not cull on the GPU.
	cull_readback_batches:  int,
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
		engine.frame_data[i].indirect_buffer = backend.buffer_create(
			DrawIndexedIndirectCommand,
			&engine.vk_ctx,
			MAX_INDIRECT_COMMANDS_PER_FRAME,
			{.Storage, .Indirect},
			.Upload,
		)
		engine.frame_data[i].particle_buffer = create_particle_buffer(&engine.vk_ctx)
		engine.frame_data[i].cull_candidates = backend.buffer_create(
			GpuCullCandidate,
			&engine.vk_ctx,
			MAX_INSTANCE_IDS,
			{.Storage},
			.Shared,
		)
		engine.frame_data[i].cull_runs = backend.buffer_create(
			GpuCullRun,
			&engine.vk_ctx,
			MAX_INDIRECT_COMMANDS_PER_FRAME,
			{.Storage},
			.Shared,
		)
		engine.frame_data[i].cull_output_ids = backend.buffer_create(
			u32,
			&engine.vk_ctx,
			MAX_INSTANCE_IDS,
			{.Storage, .Transfer_Src},
			.Gpu,
		)
		engine.frame_data[i].cull_commands = backend.buffer_create(
			DrawIndexedIndirectCommand,
			&engine.vk_ctx,
			MAX_INDIRECT_COMMANDS_PER_FRAME,
			{.Storage, .Indirect, .Transfer_Src},
			.Gpu,
		)
		engine.frame_data[i].cull_readback_commands = backend.buffer_create(
			DrawIndexedIndirectCommand,
			&engine.vk_ctx,
			MAX_INDIRECT_COMMANDS_PER_FRAME,
			{.Transfer_Dst},
			.Readback,
		)
		// Only the validator reads ids back.
		if engine.gpu_cull_validate {
			engine.frame_data[i].cull_readback_ids = backend.buffer_create(
				u32,
				&engine.vk_ctx,
				MAX_INSTANCE_IDS,
				{.Transfer_Dst},
				.Readback,
			)
		}
		engine.frame_data[i].cull_planes = backend.buffer_create(Vec4, &engine.vk_ctx, 6, {.Storage}, .Shared)
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
		backend.buffer_destroy(&engine.vk_ctx, res.indirect_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.cull_candidates)
		backend.buffer_destroy(&engine.vk_ctx, res.cull_runs)
		backend.buffer_destroy(&engine.vk_ctx, res.cull_output_ids)
		backend.buffer_destroy(&engine.vk_ctx, res.cull_commands)
		backend.buffer_destroy(&engine.vk_ctx, res.cull_planes)
		if backend.buffer_is_valid(&engine.vk_ctx, res.cull_readback_ids) do backend.buffer_destroy(&engine.vk_ctx, res.cull_readback_ids)
		if backend.buffer_is_valid(&engine.vk_ctx, res.cull_readback_commands) do backend.buffer_destroy(&engine.vk_ctx, res.cull_readback_commands)
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

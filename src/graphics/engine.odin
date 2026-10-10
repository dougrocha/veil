package graphics

import "base:intrinsics"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:time"

import sdl "vendor:sdl3"

import "backend"

@(shader_shared)
SkyboxPushConstants :: struct #max_field_align(16) {
	scene_data: backend.GPUPtr(SceneData),
}

// Init failure is fatal: on false the caller exits without engine_destroy and the OS and
// driver reclaim whatever was created. Don't retry or keep running after a failed create.
engine_create :: proc(
	engine: ^Engine,
	window: ^sdl.Window,
	width, height: u32,
	config := EngineConfig{},
) -> (
	ok: bool,
) {
	if err := virtual.arena_init_growing(&engine.frame_arena); err != nil {
		log.errorf("Failed to create engine frame arena: %v", err)
		return false
	}
	engine.config = config
	engine.settings = RENDER_SETTINGS_DEFAULT
	frame_dump_init(engine)
	debug_env_init(engine)

	vk_ctx := &engine.vk_ctx
	backend.context_init(vk_ctx, window) or_return

	// The cube array and the 2 fixed depth slots count against the same per-stage sampled-image limit.
	limits := backend.limits(vk_ctx)
	max_bindless_textures := min(MAX_TEXTURES, limits.max_bindless_textures_per_stage - BINDLESS_CUBE_COUNT - 2)

	shader_system_create(engine, max_bindless_textures) or_return
	texture_system_create(engine, {max_textures_count = max_bindless_textures})
	material_system_create(engine, {max_material_count = MAX_MATERIALS})
	model_system_create(engine)

	shadows_create(vk_ctx, &engine.shadows)
	render_targets_create(engine, width, height)
	frame_data_create(engine)
	draw_history_create(&engine.prev_draws)
	gpu_profiler_create(engine)

	pipelines_create(engine) or_return

	line_renderer_create(engine) or_return
	ui_renderer_create(engine)

	return true
}

// Exact reverse of engine_create.
engine_destroy :: proc(self: ^Engine) {
	backend.device_wait_idle(&self.vk_ctx)

	ui_renderer_destroy(self)
	line_renderer_destroy(self)
	pipelines_destroy(self)

	gpu_profiler_destroy(self)
	draw_history_destroy(&self.prev_draws)
	frame_data_destroy(self)
	render_targets_destroy(self)
	shadows_destroy(&self.vk_ctx, &self.shadows)

	model_system_destroy(self)
	material_system_destroy(self)
	texture_system_destroy(self)
	shader_system_destroy(self)

	backend.context_destroy(&self.vk_ctx)

	frame_dump_destroy(self)
	virtual.arena_destroy(&self.frame_arena)
}

// Draws packet from its camera. width/height: the window's drawable size this frame; used when
// the swapchain must be recreated.
engine_render :: proc(engine: ^Engine, packet: ^FramePacket, width, height: u32) -> bool {
	context.temp_allocator = virtual.arena_allocator(&engine.frame_arena)
	defer free_all(context.temp_allocator)
	defer stats_memory_sample(engine) // deferred later, so it runs before free_all
	// Batches are filled every tick; drain them even when this frame isn't drawn, or they overflow.
	defer {
		line_renderer_clear(engine)
		ui_renderer_clear(engine)
		debug_view_clear(engine)
	}
	// Wall clock, not packet time: a paused or slowed game still renders at the real rate.
	frame_ms: f64
	if engine.last_render != {} do frame_ms = tick_ms(engine.last_render)
	engine.last_render = time.tick_now()
	// Before frame_begin, so a skipped frame still keeps the packet; its changes carry over.
	draw_history_sync(engine, packet)

	wait_start := time.tick_now()
	cmd, ok := render_targets_begin_frame(engine, width, height)
	if !ok do return false

	engine.frame_count += 1
	gpu_profiler_collect(engine)
	wait_ms := tick_ms(wait_start)
	record_start := time.tick_now()

	// Reload first: a shadow shader reload invalidates the cache, and the plan must see it.
	shader_poll_hotreload(engine)
	shadow_plan_update(engine, packet)
	scene_data_buffer_update(engine, packet)
	update_transforms_buffer(engine)

	instance_ids_reset(engine)
	record_frame(engine, packet, cmd)
	record_ms := tick_ms(record_start)
	submit_start := time.tick_now()

	render_targets_end_frame(engine, cmd)
	// Once per recorded frame, shadow passes on or off. Skipped frames return early above, so their
	// changes carry over.
	shadow_cache_commit(&engine.shadows.cache, &engine.shadows.plan, packet.lights)
	clear(&engine.prev_draws.changes)
	engine.shadows.plan.views = nil // frame arena memory, freed when engine_render returns
	stats_add_timings(engine, {frame = frame_ms, wait = wait_ms, record = record_ms, submit = tick_ms(submit_start)})

	if engine.frame_dump.enabled {
		backend.device_wait_idle(&engine.vk_ctx)
		pick_test_run(engine, packet)
		if frame_dump_capture(engine) {
			quit := sdl.Event {
				type = .QUIT,
			}
			_ = sdl.PushEvent(&quit)
		}
	}
	return true
}

draw_input :: proc(engine: ^Engine) -> DrawInput {
	return {
		draws = draw_history_live(&engine.prev_draws),
		models = &engine.model_system.models,
		materials = &engine.material_system.materials,
	}
}

current_frame_data :: #force_inline proc(engine: ^Engine) -> ^FrameData {
	return &engine.frame_data[backend.frame_slot(&engine.vk_ctx)]
}

dispatch_particles :: proc(engine: ^Engine, packet: ^FramePacket, cmd: backend.CommandBuffer) {
	pipeline := pipeline_get(engine, .Particle_Simulate)

	frame_res_index := backend.frame_slot(&engine.vk_ctx)
	last_frame := (frame_res_index + backend.MAX_FRAMES_IN_FLIGHT - 1) % backend.MAX_FRAMES_IN_FLIGHT
	compute_pc := ParticlePushConstants {
		particles_in  = backend.buffer_address(&engine.vk_ctx, engine.frame_data[last_frame].particle_buffer),
		particles_out = backend.buffer_address(&engine.vk_ctx, engine.frame_data[frame_res_index].particle_buffer),
		delta_time    = packet.delta_time,
	}
	encoder := backend.begin_compute_pass(&engine.vk_ctx, cmd)
	// particles_in was written by the previous frame's dispatch in an earlier submission.
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	backend.pipeline_bind_compute(encoder, pipeline)
	backend.pipeline_push_compute(encoder, &compute_pc)
	// Keep the local size in sync with particle.slang's numthreads declaration.
	#assert(PARTICLE_COUNT % 256 == 0)
	backend.cmd_dispatch(encoder, PARTICLE_COUNT / 256, 1, 1, {256, 1, 1})
	backend.cmd_barrier_compute_write_to_vertex_read(encoder)
	backend.end_compute_pass(encoder)
}

draw_particles :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	pipeline := pipeline_get(engine, .Particle)

	frame_res_index := backend.frame_slot(&engine.vk_ctx)
	particle_pc := ParticlePushConstants {
		scene_data    = backend.buffer_address(&engine.vk_ctx, engine.frame_data[frame_res_index].scene_data_buffer),
		particles_out = backend.buffer_address(&engine.vk_ctx, engine.frame_data[frame_res_index].particle_buffer),
	}
	backend.pipeline_bind(cmd, pipeline)
	backend.pipeline_push(cmd, &particle_pc)
	backend.cmd_draw_points(cmd, PARTICLE_COUNT)
	stats_count_draw(engine)
}

// Each frame slot has its own transforms buffer, so draw_history_sync marks every changed id dirty in
// all of them; a buffer is then patched only where its own marks say.
update_transforms_buffer :: proc(engine: ^Engine) {
	frame := current_frame_data(engine)
	transforms := (^GpuTransform)(backend.buffer_contents(&engine.vk_ctx, frame.transforms_buffer))
	for &word, word_i in frame.transforms_dirty {
		for word != 0 {
			bit := int(intrinsics.count_trailing_zeros(word))
			word &= word - 1
			transform_write(engine, transforms, word_i * 64 + bit)
		}
	}
}

// Skips a free id: nothing draws it, and reusing it records a Spawn change.
@(private = "file")
transform_write :: proc(engine: ^Engine, transforms: ^GpuTransform, slot: int) {
	record := engine.prev_draws.records[slot]
	if record.model == INVALID_MODEL do return
	model_matrix := record.world
	normal3 := linalg.transpose(linalg.inverse(linalg.matrix3_from_matrix4(model_matrix)))

	mem.ptr_offset(transforms, slot)^ = GpuTransform {
		model         = model_matrix,
		normal_matrix = linalg.matrix4_from_matrix3(normal3),
	}
}

draw_shadow :: proc(
	engine: ^Engine,
	cmd: backend.RenderEncoder,
	light_type: LightType,
	light_i: u32,
	view_proj: Mat4x4,
	runs: []DrawRun,
) {
	directional := light_type == .Directional
	shadow_pipeline := pipeline_get(engine, .Shadow_Directional if directional else .Shadow)

	backend.pipeline_bind(cmd, shadow_pipeline)
	backend.cmd_set_depth_bias(cmd, 1.25, 0, 1.75)

	frame := current_frame_data(engine)

	for batch in draw_runs_upload(engine, runs) {
		mesh := batch.mesh
		pc := ShadowPushConstants {
			view_proj        = view_proj,
			scene_data       = backend.buffer_address(&engine.vk_ctx, frame.scene_data_buffer),
			vertex_buffer    = backend.buffer_address(&engine.vk_ctx, mesh.vertex_buffer),
			material_buffer  = backend.buffer_address(&engine.vk_ctx, engine.material_system.buffer),
			transform_buffer = backend.buffer_address(&engine.vk_ctx, frame.transforms_buffer),
			instance_ids     = backend.buffer_address(&engine.vk_ctx, frame.instance_ids_buffer),
			instance_offset  = batch.first_id,
			light_type       = light_type,
			light_index      = light_i,
			material_index   = u32(mesh.material.index),
		}
		backend.pipeline_push(cmd, &pc)
		backend.cmd_draw_indexed(cmd, mesh.index_buffer, mesh.index_count, batch.count)
		stats_count_draw(engine, u64(mesh.index_count / 3 * batch.count))
	}
}

// The camera's draw list for this frame. Counts its culling stats.
view_draw_list :: proc(engine: ^Engine, packet: ^FramePacket) -> DrawList {
	frustum := frustum_create_from_camera(&packet.camera, render_aspect(engine))
	list := build_draw_list(draw_input(engine), frustum, packet.camera.position)
	engine.stats.counters.draws_visible += list.draws_visible
	engine.stats.counters.meshes_culled += list.meshes_culled
	return list
}

// A shadow view's draw runs: the cached casters inside its frustum. Directional cascades ignore the near
// plane, since their depth is clamped rather than clipped.
shadow_view_runs :: proc(engine: ^Engine, light_type: LightType, view_proj: Mat4x4) -> []DrawRun {
	frustums := []Frustum{frustum_from_view_proj(view_proj)}
	return shadow_casters_filter(
		&engine.shadows.casters,
		draw_history_live(&engine.prev_draws),
		frustums,
		skip_near = light_type == .Directional,
	)
}

draw_meshes_opaque :: proc(engine: ^Engine, cmd: backend.RenderEncoder, list: DrawList) {
	bound: Maybe(PipelineKind)
	for batch in draw_runs_upload(engine, list.opaque) {
		kind: PipelineKind = .Mesh_Double_Sided if mesh_double_sided(engine, batch.mesh) else .Mesh
		if bound != kind {
			backend.pipeline_bind(cmd, pipeline_get(engine, kind))
			bound = kind
		}
		mesh_draw_batch(engine, cmd, batch)
	}
}

// Back to front, one draw per mesh so the order holds. Draw after everything opaque, skybox
// included: these don't write depth, so anything drawn later would cover them.
draw_meshes_transparent :: proc(engine: ^Engine, cmd: backend.RenderEncoder, list: DrawList) {
	bound: Maybe(PipelineKind)
	for item in list.transparent {
		kind: PipelineKind =
			.Mesh_Transparent_Double_Sided if mesh_double_sided(engine, item.mesh) else .Mesh_Transparent
		if bound != kind {
			backend.pipeline_bind(cmd, pipeline_get(engine, kind))
			bound = kind
		}
		batch := single_draw_batch(engine, item) or_break
		mesh_draw_batch(engine, cmd, batch)
	}
}

@(private = "file")
mesh_double_sided :: proc(engine: ^Engine, mesh: ^Mesh) -> bool {
	return pool_get(&engine.material_system.materials, mesh.material).double_sided
}

@(private = "file")
mesh_draw_batch :: proc(engine: ^Engine, cmd: backend.RenderEncoder, batch: DrawBatch) {
	frame := current_frame_data(engine)
	mesh := batch.mesh
	pc := MeshPushConstants {
		scene_data       = backend.buffer_address(&engine.vk_ctx, frame.scene_data_buffer),
		vertex_buffer    = backend.buffer_address(&engine.vk_ctx, mesh.vertex_buffer),
		material_buffer  = backend.buffer_address(&engine.vk_ctx, engine.material_system.buffer),
		transform_buffer = backend.buffer_address(&engine.vk_ctx, frame.transforms_buffer),
		instance_ids     = backend.buffer_address(&engine.vk_ctx, frame.instance_ids_buffer),
		material_index   = u32(mesh.material.index),
		instance_offset  = batch.first_id,
	}
	backend.pipeline_push(cmd, &pc)
	backend.cmd_draw_indexed(cmd, mesh.index_buffer, mesh.index_count, batch.count)
	stats_count_draw(engine, u64(mesh.index_count / 3 * batch.count))
}

draw_skybox :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	pipeline := pipeline_get(engine, .Skybox)
	backend.pipeline_bind(cmd, pipeline)
	pc := SkyboxPushConstants {
		scene_data = backend.buffer_address(&engine.vk_ctx, current_frame_data(engine).scene_data_buffer),
	}
	backend.pipeline_push(cmd, &pc)
	backend.cmd_draw(cmd)
	stats_count_draw(engine)
}

draw_ui :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	pipeline := pipeline_get(engine, .UI)
	backend.pipeline_bind(cmd, pipeline)
	ui_renderer_flush(engine, cmd)
}

record_frame :: proc(engine: ^Engine, packet: ^FramePacket, cmd: backend.CommandBuffer) {
	stats_record_begin(engine)
	defer stats_record_end(engine)
	engine.stats.counters.shadow_views_cached = engine.shadows.plan.views_cached
	gpu_profiler_reset(engine, cmd)

	frame_scope := gpu_scope_begin(engine, cmd, "frame")
	run_passes(engine, packet, cmd)
	gpu_scope_end(engine, cmd, frame_scope)
}

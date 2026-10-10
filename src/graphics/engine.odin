package graphics

import "base:intrinsics"
import "core:log"
import "core:math/linalg"
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

	device_create(engine, window) or_return
	assets_create(engine) or_return
	renderer_create(engine, width, height) or_return

	return true
}

// Each group's destroy is the mirror of its create, and the groups nest: renderer, then assets,
// then device. engine_destroy calls them in that order.
engine_destroy :: proc(self: ^Engine) {
	backend.device_wait_idle(&self.vk_ctx)

	renderer_destroy(self)
	assets_destroy(self)
	device_destroy(self)

	frame_dump_destroy(self)
	virtual.arena_destroy(&self.frame_arena)
}

// The instance and device. Created first, destroyed last: backend.context_destroy asserts that every
// image, buffer and shader is already gone. The swapchain belongs to the render targets.
@(private = "file")
device_create :: proc(engine: ^Engine, window: ^sdl.Window) -> bool {
	return backend.context_init(&engine.vk_ctx, window)
}

@(private = "file")
device_destroy :: proc(engine: ^Engine) {
	backend.context_destroy(&engine.vk_ctx)
}

// Shaders, the texture system (which owns the bindless table), materials and models. Needs the device.
@(private = "file")
assets_create :: proc(engine: ^Engine) -> bool {
	// The cube array and the 2 fixed depth slots count against the same per-stage sampled-image limit.
	limits := backend.limits(&engine.vk_ctx)
	max_bindless_textures := min(MAX_TEXTURES, limits.max_bindless_textures_per_stage - BINDLESS_CUBE_COUNT - 2)

	shader_system_create(engine, max_bindless_textures) or_return
	texture_system_create(engine, {max_textures_count = max_bindless_textures})
	material_system_create(engine, {max_material_count = MAX_MATERIALS})
	model_system_create(engine)
	return true
}

// Runs after renderer_destroy: pipelines need the shaders, and render targets and shadows need texture slots.
@(private = "file")
assets_destroy :: proc(engine: ^Engine) {
	model_system_destroy(engine)
	material_system_destroy(engine)
	texture_system_destroy(engine)
	shader_system_destroy(engine)
}

// Everything that draws a frame: shadow atlases and render targets with the swapchain (both take
// bindless slots, so they need assets), per-slot buffers, the GPU profiler, and the pipelines and
// batch renderers that record into them.
@(private = "file")
renderer_create :: proc(engine: ^Engine, width, height: u32) -> bool {
	shadows_create(&engine.vk_ctx, &engine.shadows)
	render_targets_create(engine, width, height)
	frame_data_create(engine)
	draw_history_create(&engine.prev_draws)
	gpu_profiler_create(engine)

	pipelines_create(engine) or_return
	line_renderer_create(engine) or_return
	ui_renderer_create(engine)
	return true
}

@(private = "file")
renderer_destroy :: proc(engine: ^Engine) {
	ui_renderer_destroy(engine)
	line_renderer_destroy(engine)
	pipelines_destroy(engine)

	gpu_profiler_destroy(engine)
	draw_history_destroy(&engine.prev_draws)
	frame_data_destroy(engine)
	render_targets_destroy(engine)
	shadows_destroy(&engine.vk_ctx, &engine.shadows)
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
	encoder := backend.begin_compute_pass(cmd)
	// particles_in was written by the previous frame's dispatch in an earlier submission.
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	backend.pipeline_bind_compute(encoder, pipeline)
	backend.pipeline_push_compute(encoder, &compute_pc)
	#assert(PARTICLE_COUNT % PARTICLE_GROUP_SIZE == 0)
	backend.cmd_dispatch(encoder, PARTICLE_COUNT / PARTICLE_GROUP_SIZE, 1, 1)
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
	first, last, dirty := transforms_dirty_range(frame.transforms_dirty[:])
	if !dirty do return

	transforms := backend.buffer_map_write(&engine.vk_ctx, frame.transforms_buffer, first, last - first + 1)
	for &word, word_i in frame.transforms_dirty {
		for word != 0 {
			bit := int(intrinsics.count_trailing_zeros(word))
			word &= word - 1
			transform_write(engine, transforms, first, word_i * 64 + bit)
		}
	}
}

// Lowest and highest set draw id; dirty is false when no id is set.
@(private = "file")
transforms_dirty_range :: proc(dirty: []u64) -> (first, last: int, ok: bool) {
	first = -1
	for word, word_i in dirty {
		if word == 0 do continue
		if first < 0 do first = word_i * 64 + int(intrinsics.count_trailing_zeros(word))
		last = word_i * 64 + 63 - int(intrinsics.count_leading_zeros(word))
	}
	return first, last, first >= 0
}

// Skips a free id: nothing draws it, and reusing it records a Spawn change.
// window holds ids [first, ...) of the mapped transforms buffer.
@(private = "file")
transform_write :: proc(engine: ^Engine, window: []GpuTransform, first: int, slot: int) {
	record := engine.prev_draws.records[slot]
	if record.model == INVALID_MODEL do return
	model_matrix := record.world
	normal3 := linalg.transpose(linalg.inverse(linalg.matrix3_from_matrix4(model_matrix)))

	window[slot - first] = GpuTransform {
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
	backend.cmd_bind_index_buffer(cmd, engine.model_system.index_buffer)
	backend.cmd_set_depth_bias(cmd, 1.25, 0, 1.75)

	frame := current_frame_data(engine)
	// Same for every batch in this view; shared geometry and frame addresses are pass constants.
	view_pc := ShadowPushConstants {
		view_proj        = view_proj,
		scene_data       = backend.buffer_address(&engine.vk_ctx, frame.scene_data_buffer),
		vertex_buffer    = backend.buffer_address(&engine.vk_ctx, engine.model_system.vertex_buffer),
		material_buffer  = backend.buffer_address(&engine.vk_ctx, engine.material_system.buffer),
		transform_buffer = backend.buffer_address(&engine.vk_ctx, frame.transforms_buffer),
		instance_ids     = backend.buffer_address(&engine.vk_ctx, frame.instance_ids_buffer),
		light_type       = light_type,
		light_index      = light_i,
	}
	backend.pipeline_push(cmd, &view_pc)

	batches := draw_runs_upload(engine, runs)
	start := draw_batches_indirect_upload(engine, batches)
	if len(batches) > 0 {
		backend.cmd_draw_indexed_indirect(
			cmd,
			frame.indirect_buffer,
			u64(start * size_of(DrawIndexedIndirectCommand)),
			u32(len(batches)),
			u32(size_of(DrawIndexedIndirectCommand)),
		)
		stats_count_indirect_call(engine)
	}
	for batch in batches {
		mesh := batch.mesh
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
	pass_pc := mesh_pass_push_constants(engine)
	batches := draw_runs_upload(engine, list.opaque)
	for i in 1 ..< len(batches) {
		j := i
		for j > 0 && mesh_double_sided(engine, batches[j].mesh) && !mesh_double_sided(engine, batches[j - 1].mesh) {
			temp := batches[j]
			batches[j] = batches[j - 1]
			batches[j - 1] = temp
			j -= 1
		}
	}
	start := draw_batches_indirect_upload(engine, batches)
	backend.pipeline_push(cmd, &pass_pc)
	group_start := 0
	for group_start < len(batches) {
		kind: PipelineKind = .Mesh_Double_Sided if mesh_double_sided(engine, batches[group_start].mesh) else .Mesh
		group_end := group_start + 1
		for group_end < len(batches) {
			next_kind: PipelineKind =
				.Mesh_Double_Sided if mesh_double_sided(engine, batches[group_end].mesh) else .Mesh
			if next_kind != kind do break
			group_end += 1
		}
		backend.pipeline_bind(cmd, pipeline_get(engine, kind))
		backend.cmd_draw_indexed_indirect(
			cmd,
			current_frame_data(engine).indirect_buffer,
			u64((start + group_start) * size_of(DrawIndexedIndirectCommand)),
			u32(group_end - group_start),
			u32(size_of(DrawIndexedIndirectCommand)),
		)
		stats_count_indirect_call(engine)
		for batch in batches[group_start:group_end] {
			stats_count_draw(engine, u64(batch.mesh.index_count / 3 * batch.count))
		}
		group_start = group_end
	}
}

// Back to front, one draw per mesh so the order holds. Draw after everything opaque, skybox
// included: these don't write depth, so anything drawn later would cover them.
draw_meshes_transparent :: proc(engine: ^Engine, cmd: backend.RenderEncoder, list: DrawList) {
	pass_pc := mesh_pass_push_constants(engine)
	bound: Maybe(PipelineKind)
	for item in list.transparent {
		kind: PipelineKind =
			.Mesh_Transparent_Double_Sided if mesh_double_sided(engine, item.mesh) else .Mesh_Transparent
		if bound != kind {
			backend.pipeline_bind(cmd, pipeline_get(engine, kind))
			backend.pipeline_push(cmd, &pass_pc)
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

// The fields every mesh draw in a pass shares. Frame buffers and the material buffer keep their
// addresses for the whole pass.
@(private = "file")
mesh_pass_push_constants :: proc(engine: ^Engine) -> MeshPushConstants {
	frame := current_frame_data(engine)
	return MeshPushConstants {
		scene_data = backend.buffer_address(&engine.vk_ctx, frame.scene_data_buffer),
		vertex_buffer = backend.buffer_address(&engine.vk_ctx, engine.model_system.vertex_buffer),
		material_buffer = backend.buffer_address(&engine.vk_ctx, engine.material_system.buffer),
		transform_buffer = backend.buffer_address(&engine.vk_ctx, frame.transforms_buffer),
		instance_ids = backend.buffer_address(&engine.vk_ctx, frame.instance_ids_buffer),
	}
}

@(private = "file")
mesh_draw_batch :: proc(engine: ^Engine, cmd: backend.RenderEncoder, batch: DrawBatch) {
	mesh := batch.mesh
	backend.cmd_draw_indexed(cmd, mesh.index_count, batch.count, mesh.first_index, mesh.first_vertex, batch.first_id)
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

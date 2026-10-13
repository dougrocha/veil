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
	if engine.gpu_cull_validate && !engine.gpu_cull_validated {
		backend.device_wait_idle(&engine.vk_ctx)
		gpu_cull_validate_frame(engine, packet)
		engine.gpu_cull_validated = true
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

// Commands a run takes: one per GPU_CULL_BATCH_CANDIDATES ids. An empty run keeps one, so its draw stays counted.
gpu_cull_batch_count :: proc(id_count: int) -> int {
	return max(1, (id_count + GPU_CULL_BATCH_CANDIDATES - 1) / GPU_CULL_BATCH_CANDIDATES)
}

dispatch_gpu_cull :: proc(engine: ^Engine, packet: ^FramePacket, cmd: backend.CommandBuffer, runs: []DrawRun) -> bool {
	frame := current_frame_data(engine)
	engine.gpu_cull_validate_slot = backend.frame_slot(&engine.vk_ctx)
	frame.cull_batch_count = 0
	frame.cull_candidate_count = 0
	candidate_count, batch_count: int
	candidates := make([dynamic]GpuCullCandidate, context.temp_allocator)
	run_data := make([dynamic]GpuCullRun, context.temp_allocator)
	// Batches stay in run order and candidate order, so each batch's output lands at its own first_candidate.
	for run in runs {
		run_ids := len(run.ids)
		run_batches := gpu_cull_batch_count(run_ids)
		if candidate_count + run_ids > MAX_INSTANCE_IDS || batch_count + run_batches > MAX_INDIRECT_COMMANDS_PER_FRAME do return false
		mesh := run.mesh
		for b in 0 ..< run_batches {
			first := min(b * GPU_CULL_BATCH_CANDIDATES, run_ids)
			last := min(first + GPU_CULL_BATCH_CANDIDATES, run_ids)
			append(
				&run_data,
				GpuCullRun {
					first_candidate = u32(candidate_count),
					candidate_count = u32(last - first),
					first_index = mesh.first_index,
					vertex_offset = i32(mesh.first_vertex),
					index_count = mesh.index_count,
					bounds_center = Vec4{mesh.bounds.center.x, mesh.bounds.center.y, mesh.bounds.center.z, 0},
					bounds_extents = Vec4{mesh.bounds.extents.x, mesh.bounds.extents.y, mesh.bounds.extents.z, 0},
				},
			)
			for id in run.ids[first:last] {
				packed := (u32(id) << u32(INSTANCE_DRAW_ID_SHIFT)) | u32(mesh.material.index)
				append(&candidates, GpuCullCandidate{packed_id = packed, run_index = u32(batch_count)})
			}
			candidate_count += last - first
			batch_count += 1
		}
	}
	if batch_count == 0 do return true
	frame.cull_batch_count = batch_count
	frame.cull_candidate_count = candidate_count
	backend.buffer_write_slice(&engine.vk_ctx, frame.cull_candidates, candidates[:])
	backend.buffer_write_slice(&engine.vk_ctx, frame.cull_runs, run_data[:])
	frustum := frustum_create_from_camera(&packet.camera, render_aspect(engine))
	planes: [6]Vec4
	for plane, i in frustum.planes do planes[i] = Vec4{plane.normal.x, plane.normal.y, plane.normal.z, plane.distance}
	backend.buffer_write_slice(&engine.vk_ctx, frame.cull_planes, planes[:])
	pc := GpuCullPushConstants {
		candidates      = backend.buffer_address(&engine.vk_ctx, frame.cull_candidates),
		runs            = backend.buffer_address(&engine.vk_ctx, frame.cull_runs),
		transforms      = backend.buffer_address(&engine.vk_ctx, frame.transforms_buffer),
		planes          = backend.buffer_address(&engine.vk_ctx, frame.cull_planes),
		output_ids      = backend.buffer_address(&engine.vk_ctx, frame.cull_output_ids),
		commands        = backend.buffer_address(&engine.vk_ctx, frame.cull_commands),
		candidate_count = u32(candidate_count),
		run_count       = u32(batch_count),
	}
	encoder := backend.begin_compute_pass(cmd)
	scope := gpu_scope_begin(engine, cmd, "culling")
	backend.cmd_barrier_host_write_to_compute(encoder)
	backend.pipeline_bind_compute(encoder, pipeline_get(engine, .Gpu_Cull))
	pc.init_commands = 1
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, (u32(batch_count) + 255) / 256, 1, 1)
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	pc.init_commands = 0
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, (u32(candidate_count) + 255) / 256, 1, 1)
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	pc.init_commands = 2
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, (u32(batch_count) + 255) / 256, 1, 1)
	if engine.gpu_cull_validate {
		backend.cmd_barrier_compute_write_to_transfer_read(encoder)
		backend.cmd_copy_buffer(cmd, frame.cull_commands, frame.cull_readback_commands, batch_count)
		backend.cmd_barrier_transfer_write_to_host_read(cmd, frame.cull_readback_commands)
		// A zero-size copy is invalid. Runs can all be empty, which leaves no candidates to read back.
		if candidate_count > 0 {
			backend.cmd_copy_buffer(cmd, frame.cull_output_ids, frame.cull_readback_ids, candidate_count)
			backend.cmd_barrier_transfer_write_to_host_read(cmd, frame.cull_readback_ids)
		}
	}
	backend.cmd_barrier_compute_write_to_draw_read(encoder)
	backend.end_compute_pass(encoder)
	gpu_scope_end(engine, cmd, scope)
	return true
}

gpu_cull_validate_frame :: proc(engine: ^Engine, packet: ^FramePacket) {
	frame := &engine.frame_data[engine.gpu_cull_validate_slot]
	if frame.cull_batch_count == 0 do return
	commands := make([]DrawIndexedIndirectCommand, frame.cull_batch_count, context.temp_allocator)
	ids := make([]u32, frame.cull_candidate_count, context.temp_allocator)
	backend.buffer_read(&engine.vk_ctx, frame.cull_readback_commands, commands)
	if frame.cull_candidate_count > 0 do backend.buffer_read(&engine.vk_ctx, frame.cull_readback_ids, ids)
	frustum := frustum_create_from_camera(&packet.camera, render_aspect(engine))
	candidate_runs := build_draw_list(draw_input(engine), frustum, packet.camera.position, true).opaque
	cpu_runs := build_draw_list(draw_input(engine), frustum, packet.camera.position).opaque
	false_negatives, extras, kept, structural: int
	command_index, candidate_offset := 0, 0
	for gpu_run, run_index in candidate_runs {
		cpu_ids: []u32
		for cpu_run in cpu_runs {
			if cpu_run.mesh == gpu_run.mesh {
				cpu_ids = make([]u32, len(cpu_run.ids), context.temp_allocator)
				for id, i in cpu_run.ids {
					cpu_ids[i] = (id << u32(INSTANCE_DRAW_ID_SHIFT)) | u32(cpu_run.mesh.material.index)
				}
				break
			}
		}
		// The expected batch layout is rebuilt here, not taken from gpu_cull_batch_count, so the validator does not
		// reuse the code it checks. An empty run still expects one batch. Each batch's output starts at its own
		// first_candidate, and the batches concatenate in candidate order.
		run_ids := len(gpu_run.ids)
		mesh := gpu_run.mesh
		gpu_ids := make([dynamic]u32, context.temp_allocator)
		for first := 0; first < run_ids || first == 0; first += GPU_CULL_BATCH_CANDIDATES {
			expected_count := max(0, min(GPU_CULL_BATCH_CANDIDATES, run_ids - first))
			expected_first := candidate_offset + first
			if command_index >= len(commands) {
				structural += 1
				log.errorf("GPU culling validation run %d: no GPU command for candidate %d", run_index, expected_first)
				continue
			}
			command := commands[command_index]
			command_index += 1
			if command.first_instance != u32(expected_first) ||
			   command.instance_count > u32(expected_count) ||
			   command.index_count != mesh.index_count ||
			   command.first_index != mesh.first_index ||
			   command.vertex_offset != i32(mesh.first_vertex) {
				structural += 1
				log.errorf(
					"GPU culling validation run %d: command %d does not match expected batch at candidate %d",
					run_index,
					command_index - 1,
					expected_first,
				)
				continue
			}
			if int(command.first_instance) + int(command.instance_count) > len(ids) {
				structural += 1
				log.errorf(
					"GPU culling validation run %d: batch at candidate %d overruns the readback",
					run_index,
					expected_first,
				)
				continue
			}
			append_elems(&gpu_ids, ..ids[command.first_instance:][:command.instance_count])
		}
		candidate_offset += run_ids
		// Ordered match: each CPU id must appear in the GPU output in the same order. Unmatched GPU ids,
		// including duplicates, count as extras.
		run_fn, matched: int
		p := 0
		for cpu_id in cpu_ids {
			q := p
			for q < len(gpu_ids) && gpu_ids[q] != cpu_id do q += 1
			if q == len(gpu_ids) {
				run_fn += 1
			} else {
				p = q + 1
				matched += 1
			}
		}
		run_extras := len(gpu_ids) - matched
		false_negatives += run_fn
		extras += run_extras
		kept += len(gpu_ids)
		if run_fn != 0 || run_extras != 0 {
			log.infof(
				"GPU culling validation run %d: mismatches=%d false negatives=%d extras=%d",
				run_index,
				run_fn + run_extras,
				run_fn,
				run_extras,
			)
			if run_fn != 0 do log.errorf("GPU culling validation found false negatives in run %d", run_index)
		}
	}
	if command_index != frame.cull_batch_count {
		structural += 1
		log.errorf("GPU culling validation: recorded %d batches, validated %d", frame.cull_batch_count, command_index)
	}
	if candidate_offset != frame.cull_candidate_count {
		structural += 1
		log.errorf(
			"GPU culling validation: recorded %d candidates, expected %d",
			frame.cull_candidate_count,
			candidate_offset,
		)
	}
	culled := frame.cull_candidate_count - kept
	log.infof(
		"GPU culling validation: batches=%d candidates=%d kept=%d culled=%d mismatches=%d false_negatives=%d extras=%d structural=%d (extras are conservative mesh-AABB visibility beyond CPU model bounds)",
		frame.cull_batch_count,
		frame.cull_candidate_count,
		kept,
		culled,
		false_negatives + extras,
		false_negatives,
		extras,
		structural,
	)
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
	available := indirect_commands_available(engine)
	indirect_count := min(len(batches), available)
	start := draw_batches_indirect_upload(engine, batches, indirect_count)
	if indirect_count > 0 {
		backend.cmd_draw_indexed_indirect(
			cmd,
			frame.indirect_buffer,
			u64(start * size_of(DrawIndexedIndirectCommand)),
			u32(indirect_count),
			u32(size_of(DrawIndexedIndirectCommand)),
		)
		stats_count_indirect_call(engine)
	}
	for batch in batches[:indirect_count] {
		mesh := batch.mesh
		stats_count_draw(engine, u64(mesh.index_count / 3 * batch.count))
	}
	for batch in batches[indirect_count:] do mesh_draw_batch(engine, cmd, batch)
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

draw_meshes_opaque :: proc(engine: ^Engine, cmd: backend.RenderEncoder, list: DrawList, gpu_culled := false) {
	pass_pc := mesh_pass_push_constants(engine)
	if gpu_culled {
		frame := current_frame_data(engine)
		pass_pc.instance_ids = backend.buffer_address(&engine.vk_ctx, frame.cull_output_ids)
		// Each run owns gpu_cull_batch_count commands in run order, so a group's commands are contiguous too.
		command_start := 0
		group_start := 0
		for group_start < len(list.opaque) {
			kind := list.opaque[group_start].kind
			assert(
				kind == .Mesh ||
				kind == .Mesh_Double_Sided ||
				kind == .Mesh_Masked ||
				kind == .Mesh_Masked_Double_Sided,
				"opaque batch needs an opaque mesh pipeline kind",
			)
			group_end := group_start + 1
			for group_end < len(list.opaque) && list.opaque[group_end].kind == kind do group_end += 1
			group_commands := 0
			for batch in list.opaque[group_start:group_end] do group_commands += gpu_cull_batch_count(len(batch.ids))
			backend.pipeline_bind(cmd, pipeline_get(engine, kind))
			backend.pipeline_push(cmd, &pass_pc)
			backend.cmd_draw_indexed_indirect(
				cmd,
				frame.cull_commands,
				u64(command_start * size_of(DrawIndexedIndirectCommand)),
				u32(group_commands),
				u32(size_of(DrawIndexedIndirectCommand)),
			)
			stats_count_indirect_call(engine)
			for batch in list.opaque[group_start:group_end] {
				stats_count_draw(engine)
				engine.stats.counters.candidate_instances += u32(len(batch.ids))
				engine.stats.counters.candidate_triangles += u64(batch.mesh.index_count / 3) * u64(len(batch.ids))
			}
			command_start += group_commands
			group_start = group_end
		}
		return
	}
	batches := draw_runs_upload(engine, list.opaque)
	available := indirect_commands_available(engine)
	indirect_count := min(len(batches), available)
	start := draw_batches_indirect_upload(engine, batches, indirect_count)
	backend.pipeline_push(cmd, &pass_pc)
	// Runs arrive kind-first, so each kind is one contiguous span.
	group_start := 0
	for group_start < len(batches) {
		kind := batches[group_start].kind
		group_end := group_start + 1
		for group_end < len(batches) && batches[group_end].kind == kind do group_end += 1
		backend.pipeline_bind(cmd, pipeline_get(engine, kind))
		indirect_end := min(group_end, indirect_count)
		if group_start < indirect_end {
			backend.cmd_draw_indexed_indirect(
				cmd,
				current_frame_data(engine).indirect_buffer,
				u64((start + group_start) * size_of(DrawIndexedIndirectCommand)),
				u32(indirect_end - group_start),
				u32(size_of(DrawIndexedIndirectCommand)),
			)
			stats_count_indirect_call(engine)
			for batch in batches[group_start:indirect_end] {
				stats_count_draw(engine, u64(batch.mesh.index_count / 3 * batch.count))
			}
		}
		direct_start := min(max(group_start, indirect_count), group_end)
		for batch in batches[direct_start:group_end] do mesh_draw_batch(engine, cmd, batch)
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

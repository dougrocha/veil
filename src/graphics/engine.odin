package graphics

import "core:log"
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
	backend.context_init(&engine.vk_ctx, window) or_return
	// Each directional light renders its cascades as the views of one multiview pass.
	limits := backend.limits(&engine.vk_ctx)
	if limits.max_multiview_views < SHADOW_MAP_CASCADE_COUNT {
		log.errorf(
			"Device supports %d multiview views, cascades need %d",
			limits.max_multiview_views,
			SHADOW_MAP_CASCADE_COUNT,
		)
		backend.context_destroy(&engine.vk_ctx)
		return false
	}
	return true
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
	// The nil texture takes bindless slot 0, so one fewer is usable.
	texture_system_create(engine, {max_textures_count = max_bindless_textures - 1})
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
	gpu_cull_collect(engine)
	wait_ms := tick_ms(wait_start)
	record_start := time.tick_now()

	// Reload first: a shadow shader reload invalidates the cache, and the plan must see it.
	shader_poll_hotreload(engine)
	shadow_casters_sync(&engine.shadows.casters, draw_input(engine), engine.prev_draws.changes[:])
	// The frame as data first: the pass list, the host uploads and the shadow plan. Nothing records yet.
	passes, uploads, shadow_plan := frame_build(frame_input(engine, packet))
	counters := passes_counters(passes, &shadow_plan)
	if uploads.layout.dropped_runs > 0 {
		if !engine.instance_overflow_warned do log.errorf("instance id list full (%d); dropping draws", MAX_INSTANCE_IDS)
		engine.instance_overflow_warned = true
	}
	recorder := recorder_make(engine, cmd)
	frame_upload(&recorder, &uploads, passes, &engine.line_renderer, &engine.ui_renderer)
	frame_record(&recorder, passes, counters, engine.frame_count)
	record_ms := tick_ms(record_start)
	submit_start := time.tick_now()

	frame_slot := backend.frame_slot(&engine.vk_ctx)
	render_targets_end_frame(engine, cmd)
	if _, has_clusters := pass_find(passes, ClustersPass); has_clusters {
		cluster_debug_report_overflow(engine, frame_slot)
	}
	// Once per recorded frame, shadow passes on or off. Skipped frames return early above, so their
	// changes carry over.
	frame_commit(engine, packet, recorder.slot, passes, &shadow_plan, counters)
	stats_add_timings(engine, {frame = frame_ms, wait = wait_ms, record = record_ms, submit = tick_ms(submit_start)})

	if engine.frame_dump.enabled {
		backend.device_wait_idle(&engine.vk_ctx)
		if _, has_clusters := pass_find(passes, ClustersPass); has_clusters do cluster_debug_validate(engine, frame_slot)
		pick_test_run(engine, packet)
		if frame_dump_capture(engine) {
			quit := sdl.Event {
				type = .QUIT,
			}
			_ = sdl.PushEvent(&quit)
		}
	}
	if cull, ok := pass_find(passes, CullPass); ok && cull.readback && !engine.gpu_cull_validated {
		backend.device_wait_idle(&engine.vk_ctx)
		gpu_cull_validate_frame(engine, packet, recorder.slot, cull)
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

gpu_cull_validate_frame :: proc(engine: ^Engine, packet: ^FramePacket, slot: int, cull: ^CullPass) {
	// Main owns the first batches and candidates, which are all the readback holds.
	if cull.main_batches == 0 do return
	frame := &engine.frame_data[slot]
	batch_count := int(cull.main_batches)
	candidate_count := int(cull.main_candidates)
	commands := make([]DrawIndexedIndirectCommand, batch_count, context.temp_allocator)
	ids := make([]u32, candidate_count, context.temp_allocator)
	backend.buffer_read(&engine.vk_ctx, frame.cull_readback_commands, commands)
	if candidate_count > 0 do backend.buffer_read(&engine.vk_ctx, frame.cull_readback_ids, ids)
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
	if command_index != batch_count {
		structural += 1
		log.errorf("GPU culling validation: recorded %d batches, validated %d", batch_count, command_index)
	}
	if candidate_offset != candidate_count {
		structural += 1
		log.errorf("GPU culling validation: recorded %d candidates, expected %d", candidate_count, candidate_offset)
	}
	culled := candidate_count - kept
	log.infof(
		"GPU culling validation: batches=%d candidates=%d kept=%d culled=%d mismatches=%d false_negatives=%d extras=%d structural=%d (extras are conservative mesh-AABB visibility beyond CPU model bounds)",
		batch_count,
		candidate_count,
		kept,
		culled,
		false_negatives + extras,
		false_negatives,
		extras,
		structural,
	)
}

// Snapshots the retained CPU state frame_build reads: history, shadow casters and cache, pools,
// target sizes and this slot's buffer addresses. Nothing is written back.
frame_input :: proc(engine: ^Engine, packet: ^FramePacket) -> FrameInput {
	slot := backend.frame_slot(&engine.vk_ctx)
	buffers := &engine.frame_data[slot]
	bloom := backend.image_desc(&engine.vk_ctx, engine.render_targets.bloom)
	// With a color background nothing samples the sky cube; the black default keeps the slot valid.
	sky := engine.texture_system.defaults[.Black_Cube]
	if cube, ok := packet.background.(TextureHandle); ok do sky = cube
	return {
		packet = packet,
		history = &engine.prev_draws,
		casters = &engine.shadows.casters,
		cache = &engine.shadows.cache,
		models = &engine.model_system.models,
		materials = &engine.material_system.materials,
		sky = texture_cube_slot(engine, sky),
		targets = {
			extent = render_extent(engine),
			bloom_extent = {bloom.extent.width, bloom.extent.height},
			bloom_mips = bloom.mip_levels,
		},
		addresses = {
			point_lights = backend.buffer_address(&engine.vk_ctx, buffers.point_lights_buffer),
			spot_lights = backend.buffer_address(&engine.vk_ctx, buffers.spot_lights_buffer),
			cluster_headers = backend.buffer_address(&engine.vk_ctx, buffers.clusters.headers),
			cluster_indices = backend.buffer_address(&engine.vk_ctx, buffers.clusters.indices),
		},
		slot = slot,
		frame_count = engine.frame_count,
		budget = FRAME_BUDGET_DEFAULT,
		cull_readback = engine.gpu_cull_validate,
		cluster_validate = engine.cluster_validate,
	}
}

// Snapshots the GPU handles and buffer addresses that record needs for this slot. Holds no CPU state.
recorder_make :: proc(engine: ^Engine, cmd: backend.CommandBuffer) -> Recorder {
	slot := backend.frame_slot(&engine.vk_ctx)
	prev := (slot + backend.MAX_FRAMES_IN_FLIGHT - 1) % backend.MAX_FRAMES_IN_FLIGHT
	return {
		ctx = &engine.vk_ctx,
		cmd = cmd,
		slot = slot,
		frame = &engine.frame_data[slot],
		prev_frame = &engine.frame_data[prev],
		targets = &engine.render_targets,
		atlas_2d = engine.shadows.atlas_2d.image,
		atlas_cube = engine.shadows.point_atlas.image,
		pipelines = &engine.pipeline_registry,
		geometry = {
			index = engine.model_system.index_buffer,
			vertices = backend.buffer_address(&engine.vk_ctx, engine.model_system.vertex_buffer),
			materials = backend.buffer_address(&engine.vk_ctx, engine.material_system.buffer),
		},
		profiler = &engine.gpu_profiler,
	}
}

// Records the pass list inside the "frame" timing scope. Debug builds assert that what record emitted
// matches the counters summed from the list.
frame_record :: proc(r: ^Recorder, passes: []Pass, counters: FrameCounters, frame_count: u32) {
	gpu_profiler_reset(r, frame_count)
	scope := gpu_scope_begin(r, "frame")
	passes_record(r, passes)
	gpu_scope_end(r, scope)
	when ODIN_DEBUG {
		assert(r.tally.draw_calls == counters.draw_calls, "planned and recorded draw counts differ")
		assert(r.tally.indirect_calls == counters.indirect_calls, "planned and recorded indirect counts differ")
	}
}

// Runs once per submitted frame; a skipped frame keeps its changes and dirty bits for the next one.
frame_commit :: proc(
	engine: ^Engine,
	packet: ^FramePacket,
	slot: int,
	passes: []Pass,
	plan: ^ShadowPlan,
	counters: FrameCounters,
) {
	shadow_cache_commit(&engine.shadows.cache, plan, packet.lights)
	draw_history_commit(&engine.prev_draws, slot)
	engine.stats.last = counters
	engine.frame_data[slot].cull_readback_batches = 0
	if cull, ok := pass_find(passes, CullPass); ok do engine.frame_data[slot].cull_readback_batches = int(cull.main_batches)
}

// Reads this slot's cull commands from its last submitted frame. Call after frame begin's fence wait.
gpu_cull_collect :: proc(engine: ^Engine) {
	frame := current_frame_data(engine)
	batch_count := frame.cull_readback_batches
	frame.cull_readback_batches = 0
	engine.stats.gpu_visible = {}
	if batch_count == 0 do return
	commands := make([]DrawIndexedIndirectCommand, batch_count, context.temp_allocator)
	backend.buffer_read(&engine.vk_ctx, frame.cull_readback_commands, commands)
	visible := &engine.stats.gpu_visible
	visible.valid = true
	for command in commands {
		visible.instances += u64(command.instance_count)
		visible.triangles += u64(command.index_count / 3) * u64(command.instance_count)
	}
}

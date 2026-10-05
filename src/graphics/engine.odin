package graphics

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:time"

import sdl "vendor:sdl3"

import "backend"

// Init failure is fatal: on false the caller exits without engine_destroy and the OS and
// driver reclaim whatever was created. Don't retry or keep running after a failed create.
engine_create :: proc(engine: ^Engine, window: ^sdl.Window, width, height: u32) -> (ok: bool) {
	if err := virtual.arena_init_growing(&engine.frame_arena); err != nil {
		log.errorf("Failed to create engine frame arena: %v", err)
		return false
	}
	engine.camera_system = camera_system_create({max_camera_count = 10})
	engine.scene.active_camera_name = DEFAULT_CAMERA_NAME
	engine.debug_settings.light_mask = LIGHT_MASK_ALL
	engine.debug_settings.bloom_max_levels = BLOOM_DEFAULT_LEVELS
	engine.debug_settings.bloom_strength = BLOOM_DEFAULT_STRENGTH
	engine.debug_settings.exposure = TONEMAP_EXPOSURE
	frame_dump_init(engine)
	debug_env_init(engine)
	engine.scene.ambient_light = AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.03,
	}

	vk_ctx := &engine.vk_ctx
	backend.context_init(vk_ctx, window) or_return

	engine.swapchain = backend.swapchain_create(vk_ctx, width, height)

	// The cube array and the 2 fixed depth slots count against the same per-stage sampled-image limit.
	max_bindless_textures := min(MAX_TEXTURES, vk_ctx.max_bindless_textures_per_stage - BINDLESS_CUBE_COUNT - 2)

	shader_system_create(engine, max_bindless_textures) or_return
	texture_system_create(engine, {max_textures_count = max_bindless_textures})
	material_system_create(engine, {max_material_count = MAX_MATERIALS})
	model_system_create(engine)

	global_resources_create(engine)
	render_targets_create(engine)
	frame_data_create(engine) // particle spawn area is sized by the render extent
	gpu_profiler_create(engine)
	shadow_cache_create(engine)

	pipelines_create(engine) or_return

	line_renderer_create(engine) or_return
	ui_renderer_create(engine)

	return true
}

global_resources_create :: proc(engine: ^Engine) {
	vk_ctx := &engine.vk_ctx

	engine.shadow_atlas = shadow_atlas_create(vk_ctx, POINT_SHADOW_MAP_SIZE, MAX_POINT_LIGHTS * 6, cube = true)
	backend.bindless_write_fixed(vk_ctx, .Depth_Cube_Array, engine.shadow_atlas.image, engine.shadow_atlas.sampler)
	engine.shadow_2d_atlas = shadow_atlas_create(vk_ctx, SHADOW_MAP_SIZE, MAX_SHADOW_2D_SLOTS, cube = false)
	backend.bindless_write_fixed(vk_ctx, .Depth_2D_Array, engine.shadow_2d_atlas.image, engine.shadow_2d_atlas.sampler)
	// The skybox pass samples SceneData.skybox_cube every frame; with no skybox configured
	// the sky renders black.
	set_skybox_texture(engine, engine.texture_system.defaults[.Black_Cube])
}

global_resources_destroy :: proc(engine: ^Engine) {
	shadow_atlas_destroy(&engine.vk_ctx, &engine.shadow_2d_atlas)
	shadow_atlas_destroy(&engine.vk_ctx, &engine.shadow_atlas)
}

// Exact reverse of engine_create.
engine_destroy :: proc(self: ^Engine) {
	backend.device_wait_idle(&self.vk_ctx)

	ui_renderer_destroy(self)
	line_renderer_destroy(self)
	pipelines_destroy(self)

	shadow_cache_destroy(self)
	gpu_profiler_destroy(self)
	frame_data_destroy(self)
	render_targets_destroy(self)
	global_resources_destroy(self)

	model_system_destroy(self)
	material_system_destroy(self)
	texture_system_destroy(self)
	shader_system_destroy(self)

	backend.swapchain_destroy(&self.vk_ctx, &self.swapchain)
	backend.context_destroy(&self.vk_ctx)

	frame_dump_destroy(self)
	camera_system_destroy(&self.camera_system)
	virtual.arena_destroy(&self.frame_arena)
}

// width/height: the window's drawable size this frame; used when the swapchain must be recreated.
engine_render :: proc(engine: ^Engine, width, height: u32, delta_time: f32) {
	context.temp_allocator = virtual.arena_allocator(&engine.frame_arena)
	defer free_all(context.temp_allocator)
	defer stats_memory_sample(engine) // deferred later, so it runs before free_all
	// Batches are filled every tick; drain them even when this frame isn't drawn, or they overflow.
	defer {
		line_renderer_clear(engine)
		ui_renderer_clear(engine)
		debug_view_clear(engine)
	}

	engine.time_info.delta_time = delta_time
	engine.time_info.time += delta_time

	wait_start := time.tick_now()
	cmd, ok := backend.frame_begin(&engine.vk_ctx, &engine.swapchain, width, height)
	if !ok do return

	// The swapchain may have just been recreated; the targets follow its extent, which can differ
	// from the window size.
	render_targets_sync(engine)

	engine.time_info.frame_count += 1
	gpu_profiler_collect(engine)
	wait_ms := tick_ms(wait_start)
	record_start := time.tick_now()

	scene_data_buffer_update(engine)
	update_transforms_buffer(engine)
	shadow_cache_update(engine)
	shader_poll_hotreload(engine)
	pipelines_collect_retired(engine)

	instance_ids_reset(engine)
	record_frame(engine, cmd)
	record_ms := tick_ms(record_start)
	submit_start := time.tick_now()

	backend.frame_end(&engine.vk_ctx, &engine.swapchain, cmd, engine.render_targets.draw)
	// Cleared once per recorded frame. Skipped frames return early above, so their changes carry over.
	clear(&engine.scene.instance_changes)
	stats_add_timings(
		engine,
		{frame = f64(delta_time) * 1000, wait = wait_ms, record = record_ms, submit = tick_ms(submit_start)},
	)

	if engine.frame_dump.enabled {
		backend.device_wait_idle(&engine.vk_ctx)
		pick_test_run(engine)
		if frame_dump_capture(engine) {
			quit := sdl.Event {
				type = .QUIT,
			}
			_ = sdl.PushEvent(&quit)
		}
	}
}

scene_view :: proc(engine: ^Engine) -> SceneView {
	return {
		instances = &engine.scene.instances,
		models = &engine.model_system.models,
		materials = &engine.material_system.materials,
	}
}

current_frame_data :: #force_inline proc(engine: ^Engine) -> ^FrameData {
	return &engine.frame_data[backend.frame_slot(&engine.vk_ctx)]
}

dispatch_particles :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	pipeline := compute_pipeline(engine, .Particle)

	frame_res_index := backend.frame_slot(&engine.vk_ctx)
	last_frame := (frame_res_index + backend.MAX_FRAMES_IN_FLIGHT - 1) % backend.MAX_FRAMES_IN_FLIGHT
	compute_pc := ParticlePushConstants {
		particles_in  = backend.buffer_address(&engine.vk_ctx, engine.frame_data[last_frame].particle_buffer),
		particles_out = backend.buffer_address(&engine.vk_ctx, engine.frame_data[frame_res_index].particle_buffer),
		delta_time    = engine.time_info.delta_time,
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
	pipeline := graphics_pipeline(engine, .Particle)

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

update_transforms_buffer :: proc(engine: ^Engine) {
	transforms := (^GpuTransform)(
		backend.buffer_contents(&engine.vk_ctx, current_frame_data(engine).transforms_buffer),
	)
	for instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(i)) do continue
		model_matrix := transform_to_matrix(instance.transform)
		normal3 := linalg.transpose(linalg.inverse(linalg.matrix3_from_matrix4(model_matrix)))

		mem.ptr_offset(transforms, i)^ = GpuTransform {
			model         = model_matrix,
			normal_matrix = linalg.matrix4_from_matrix3(normal3),
		}
	}
}

draw_shadow :: proc(
	engine: ^Engine,
	cmd: backend.RenderEncoder,
	light_type: ShadowLightType,
	light_i: u32,
	view_proj: Mat4x4,
) {
	directional := light_type == .Directional
	shadow_pipeline := graphics_pipeline(engine, .Shadow_Directional if directional else .Shadow)

	backend.pipeline_bind(cmd, shadow_pipeline)
	backend.cmd_set_depth_bias(cmd, 1.25, 0, 1.75)

	frame := current_frame_data(engine)

	frustum := frustum_from_view_proj(view_proj)
	kind := DrawListKind.Shadow_Directional if directional else .Shadow
	list := build_draw_list(scene_view(engine), frustum, kind, {})

	for batch in draw_runs_upload(engine, list.opaque) {
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
view_draw_list :: proc(engine: ^Engine) -> DrawList {
	active_camera := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	frustum := frustum_create_from_camera(active_camera, render_aspect(engine))
	list := build_draw_list(scene_view(engine), frustum, .View, active_camera.position)
	engine.stats.counters.instances_drawn += list.instances_visible
	engine.stats.counters.meshes_culled += list.meshes_culled
	return list
}

draw_meshes_opaque :: proc(engine: ^Engine, cmd: backend.RenderEncoder, list: DrawList) {
	bound: Maybe(GraphicsPipelineKind)
	for batch in draw_runs_upload(engine, list.opaque) {
		kind: GraphicsPipelineKind = .Mesh_Double_Sided if mesh_double_sided(engine, batch.mesh) else .Mesh
		if bound != kind {
			backend.pipeline_bind(cmd, graphics_pipeline(engine, kind))
			bound = kind
		}
		mesh_draw_batch(engine, cmd, batch)
	}
}

// Back to front, one draw per mesh so the order holds. Draw after everything opaque, skybox
// included: these don't write depth, so anything drawn later would cover them.
draw_meshes_transparent :: proc(engine: ^Engine, cmd: backend.RenderEncoder, list: DrawList) {
	bound: Maybe(GraphicsPipelineKind)
	for item in list.transparent {
		kind: GraphicsPipelineKind =
			.Mesh_Transparent_Double_Sided if mesh_double_sided(engine, item.mesh) else .Mesh_Transparent
		if bound != kind {
			backend.pipeline_bind(cmd, graphics_pipeline(engine, kind))
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
	pc := PushConstants {
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

// Takes effect on the next recorded frame: it only changes the cube slot SceneData carries.
set_skybox_texture :: proc(engine: ^Engine, handle: TextureHandle) {
	engine.skybox_cube = texture_cube_slot(engine, handle)
}

// Shadow views each atlas renders this frame. Masked-off lights aren't sampled, so they're
// skipped. Cached maps stay valid and are re-checked when the light is enabled again.
@(private = "file")
shadow_counts :: proc(engine: ^Engine) -> (dir_count, spot_count, point_count: int) {
	dir_count = min(int(engine.scene.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	spot_count = min(int(engine.scene.spot_light_count), MAX_SPOT_LIGHTS)
	point_count = min(int(engine.scene.point_light_count), MAX_POINT_LIGHTS)
	mask := engine.debug_settings.light_mask
	if mask & u32(LightMask.Directional) == 0 do dir_count = 0
	if mask & u32(LightMask.Spot) == 0 do spot_count = 0
	if mask & u32(LightMask.Point) == 0 do point_count = 0
	return
}

@(private = "file")
current_scene_data :: proc(engine: ^Engine) -> ^SceneData {
	return (^SceneData)(backend.buffer_contents(&engine.vk_ctx, current_frame_data(engine).scene_data_buffer))
}

// 2D atlas: directional cascades first, then spot lights from SPOT_SHADOW_SLOT_BASE.
record_shadow_2d :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	scene_data := current_scene_data(engine)
	dir_count, spot_count, _ := shadow_counts(engine)
	atlas_2d := &engine.shadow_2d_atlas
	for light_i in 0 ..< dir_count {
		for cascade in 0 ..< SHADOW_MAP_CASCADE_COUNT {
			slot := u32(light_i * SHADOW_MAP_CASCADE_COUNT + cascade)
			shadow_pass(engine, cmd, atlas_2d, slot, .Directional, u32(light_i), scene_data.shadow_2d_view_proj[slot])
		}
	}
	for light_i in 0 ..< spot_count {
		if shadow_cache_spot_fresh(engine, light_i) {
			engine.stats.counters.shadow_views_cached += 1
			continue
		}
		slot := SPOT_SHADOW_SLOT_BASE + u32(light_i)
		shadow_pass(engine, cmd, atlas_2d, slot, .Spot, u32(light_i), scene_data.shadow_2d_view_proj[slot])
		shadow_cache_spot_rendered(engine, light_i)
	}
}

// Cube atlas: 6 faces per point light.
record_shadow_point :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	scene_data := current_scene_data(engine)
	_, _, point_count := shadow_counts(engine)
	atlas_cube := &engine.shadow_atlas
	for light_i in 0 ..< point_count {
		if shadow_cache_point_fresh(engine, light_i) {
			engine.stats.counters.shadow_views_cached += 6
			continue
		}
		for face_i in 0 ..< 6 {
			layer := u32(light_i * 6 + face_i)
			view_proj := scene_data.point_light_view_proj[light_i][face_i]
			shadow_pass(engine, cmd, atlas_cube, layer, .Point, u32(light_i), view_proj)
		}
		shadow_cache_point_rendered(engine, light_i)
	}
}

// Renders one atlas layer. The executor has already put the atlas in .Depth_Write.
shadow_pass :: proc(
	engine: ^Engine,
	cmd: backend.CommandBuffer,
	atlas: ^ShadowAtlas,
	layer: u32,
	light_type: ShadowLightType,
	light_index: u32,
	view_proj: Mat4x4,
) {
	encoder := backend.begin_render_pass(
		&engine.vk_ctx,
		cmd,
		backend.PassConfig{depth = {image = atlas.image, layer = layer}, load_op = .Clear, store_depth = true},
	)
	engine.stats.counters.shadow_views += 1
	draw_shadow(engine, encoder, light_type, light_index, view_proj)
	backend.end_render_pass(encoder)
}

draw_skybox :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	pipeline := graphics_pipeline(engine, .Skybox)
	backend.pipeline_bind(cmd, pipeline)
	pc := SkyboxPushConstants {
		scene_data = backend.buffer_address(&engine.vk_ctx, current_frame_data(engine).scene_data_buffer),
	}
	backend.pipeline_push(cmd, &pc)
	backend.cmd_draw(cmd)
	stats_count_draw(engine)
}

draw_ui :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	pipeline := graphics_pipeline(engine, .UI)
	backend.pipeline_bind(cmd, pipeline)
	ui_renderer_flush(engine, cmd)
}

record_frame :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	stats_record_begin(engine)
	defer stats_record_end(engine)
	gpu_profiler_reset(engine, cmd)

	frame_scope := gpu_scope_begin(engine, cmd, "frame")
	run_passes(engine, cmd)
	gpu_scope_end(engine, cmd, frame_scope)
}

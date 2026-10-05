package graphics

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:time"

import sdl "vendor:sdl3"

import "backend"

// eventually move this from init vulkan and actually make it like a init engine
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
	backend.context_init(vk_ctx, window)
	backend.upload_pool_create(vk_ctx)

	engine.swapchain = backend.swapchain_create(vk_ctx, width, height)
	engine.render_targets = render_targets_create(vk_ctx, engine.swapchain.extent)

	// The 3 global combined image samplers (shadow atlases, skybox) count against the same per-stage limit.
	max_bindless_textures := min(MAX_TEXTURES, vk_ctx.max_bindless_textures_per_stage - 3)

	shader_system_create(engine, max_bindless_textures) or_return
	shadow_handle := shader_load(engine, "shadow", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	ui_handle := shader_load(engine, "ui", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	mesh_handle := shader_load(engine, "mesh", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	particle_handle := shader_load(engine, "particle", {VERTEX_ENTRY, FRAGMENT_MAIN, COMPUTE_MAIN}) or_return
	skybox_handle := shader_load(engine, "skybox", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	debug_view_handle := shader_load(engine, "debug_view", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	tonemap_handle := shader_load(engine, "tonemap", {COMPUTE_MAIN}) or_return
	bloom_down_handle := shader_load(engine, "bloom_down", {COMPUTE_MAIN}) or_return
	bloom_up_handle := shader_load(engine, "bloom_up", {COMPUTE_MAIN}) or_return

	backend.frame_sync_create(vk_ctx)
	frame_data_create(engine)

	texture_system_create(engine, {max_textures_count = max_bindless_textures})
	material_system_create(engine, {max_material_count = MAX_MATERIALS})
	create_model_system(engine)

	global_resources_create(engine)
	post_targets_create(engine)
	gpu_profiler_create(engine)
	shadow_cache_create(engine)

	register_shadow_pipelines(engine, shadow_handle)
	register_ui_pipeline(engine, ui_handle)
	register_mesh_pipeline(engine, mesh_handle)
	register_particle_pipelines(engine, particle_handle)
	register_skybox_pipeline(engine, skybox_handle)
	register_debug_view_pipeline(engine, debug_view_handle)
	register_tonemap_pipeline(engine, tonemap_handle)
	register_bloom_pipelines(engine, bloom_down_handle, bloom_up_handle)

	line_renderer_create(engine) or_return
	ui_renderer_create(engine)

	return true
}

global_resources_create :: proc(engine: ^Engine) {
	vk_ctx := &engine.vk_ctx

	engine.global_descriptor = backend.descriptor_set_create_sampler_array(vk_ctx, 3)
	engine.shadow_atlas = shadow_atlas_create(vk_ctx, POINT_SHADOW_MAP_SIZE, MAX_POINT_LIGHTS * 6, cube = true)
	backend.descriptor_write_image_view(
		vk_ctx,
		&engine.global_descriptor,
		0,
		&engine.shadow_atlas.gpu,
		engine.shadow_atlas.sampler,
		.Depth_Read,
	)
	engine.shadow_2d_atlas = shadow_atlas_create(vk_ctx, SHADOW_MAP_SIZE, MAX_SHADOW_2D_SLOTS, cube = false)
	backend.descriptor_write_image_view(
		vk_ctx,
		&engine.global_descriptor,
		1,
		&engine.shadow_2d_atlas.gpu,
		engine.shadow_2d_atlas.sampler,
		.Depth_Read,
	)
	// The skybox pass samples binding 2 every frame, so it needs a valid cube before any
	// set_skybox_texture call; with no skybox configured the sky renders black.
	set_skybox_texture(engine, engine.texture_system.defaults[.Black_Cube])
}

engine_destroy :: proc(self: ^Engine) {
	backend.device_wait_idle(&self.vk_ctx)

	camera_system_destroy(&self.camera_system)
	frame_dump_destroy(self)
	texture_system_destroy(self)
	destroy_model_system(self)
	material_system_destroy(self)

	backend.descriptor_set_destroy(&self.vk_ctx, &self.global_descriptor)
	backend.descriptor_set_destroy(&self.vk_ctx, &self.storage_descriptor)
	shadow_atlas_destroy(&self.vk_ctx, &self.shadow_atlas)
	shadow_atlas_destroy(&self.vk_ctx, &self.shadow_2d_atlas)

	gpu_profiler_destroy(self)
	shadow_cache_destroy(self)
	line_renderer_destroy(self)
	ui_renderer_destroy(self)

	destroy_pipeline_registry(&self.vk_ctx, &self.pipeline_registry)

	shader_system_destroy(self)

	frame_data_destroy(self)
	backend.frame_sync_destroy(&self.vk_ctx)
	render_targets_destroy(&self.vk_ctx, &self.render_targets)
	backend.swapchain_destroy(&self.vk_ctx, &self.swapchain)

	backend.context_destroy(&self.vk_ctx)
	virtual.arena_destroy(&self.frame_arena)
}

engine_render :: proc(app: ^App, delta_time: f32) {
	engine := &app.engine
	context.temp_allocator = virtual.arena_allocator(&engine.frame_arena)
	defer free_all(context.temp_allocator)
	// Batches are filled every tick; drain them even when this frame isn't drawn, or they overflow.
	defer {
		line_renderer_clear(engine)
		ui_renderer_clear(engine)
		debug_view_clear(engine)
	}

	engine.time_info.delta_time = delta_time
	engine.time_info.time += delta_time

	// A minimized window has no drawable pixels; keep the old swapchain until it returns.
	if app.width == 0 || app.height == 0 do return

	if engine.swapchain.require_recreate {
		engine_resize(engine, app.width, app.height)
	}

	wait_start := time.tick_now()
	backend.frame_wait_before_render(&engine.vk_ctx, engine.frame_index)
	frame_sync := backend.current_frame_sync(&engine.vk_ctx, engine.frame_index)

	switch backend.swapchain_acquire_next_image(&engine.vk_ctx, &engine.swapchain, frame_sync) {
	case .Success:
	case .Suboptimal:
		engine.swapchain.require_recreate = true
	case .OutOfDate:
		engine.swapchain.require_recreate = true
		return
	case .NotReady:
		return
	}

	engine.time_info.frame_count += 1
	gpu_profiler_collect(engine)
	wait_ms := tick_ms(wait_start)
	record_start := time.tick_now()

	scene_data_buffer_update(engine)
	update_transforms_buffer(engine)
	shadow_cache_update(engine)
	shader_poll_hotreload(engine)

	cmd := record_command_buffer(engine)
	record_ms := tick_ms(record_start)
	submit_start := time.tick_now()

	signal_value := engine.frame_index + 1
	backend.queue_submit_frame(&engine.vk_ctx, cmd, &engine.swapchain, frame_sync, signal_value)

	switch backend.queue_present_frame(&engine.vk_ctx, cmd, &engine.swapchain, frame_sync) {
	case .Success:
	case .OutOfDate, .Suboptimal:
		engine.swapchain.require_recreate = true
	}
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

	engine.frame_index += 1
}

current_frame_res_index :: proc(engine: ^Engine) -> u64 {
	return engine.frame_index % backend.MAX_FRAMES_IN_FLIGHT
}

current_frame_data :: #force_inline proc(engine: ^Engine) -> ^FrameData {
	return &engine.frame_data[current_frame_res_index(engine)]
}

dispatch_particles :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Particle_Compute)

	frame_res_index := current_frame_res_index(engine)
	last_frame := (frame_res_index + backend.MAX_FRAMES_IN_FLIGHT - 1) % backend.MAX_FRAMES_IN_FLIGHT
	compute_pc := ParticlePushConstants {
		particles_in  = engine.frame_data[last_frame].particle_buffer.ptr,
		particles_out = engine.frame_data[frame_res_index].particle_buffer.ptr,
		delta_time    = engine.time_info.delta_time,
	}
	encoder := backend.begin_compute_pass(&engine.vk_ctx, cmd)
	// particles_in was written by the previous frame's dispatch in an earlier submission.
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	backend.pipeline_bind_compute(encoder, pipeline)
	backend.pipeline_push_compute(encoder, pipeline, &compute_pc)
	// Keep the local size in sync with particle.slang's numthreads declaration.
	#assert(PARTICLE_COUNT % 256 == 0)
	backend.cmd_dispatch(encoder, PARTICLE_COUNT / 256, 1, 1, {256, 1, 1})
	backend.cmd_barrier_compute_write_to_vertex_read(encoder)
	backend.end_compute_pass(encoder)
}

draw_particles :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Particle_Draw)

	frame_res_index := current_frame_res_index(engine)
	particle_pc := ParticlePushConstants {
		scene_data    = engine.frame_data[frame_res_index].scene_data_buffer.ptr,
		particles_out = engine.frame_data[frame_res_index].particle_buffer.ptr,
	}
	backend.pipeline_bind(cmd, pipeline)
	backend.pipeline_push(cmd, pipeline, {.Vertex, .Fragment}, &particle_pc)
	backend.cmd_draw_points(cmd, PARTICLE_COUNT)
	stats_count_draw(engine)
}

update_transforms_buffer :: proc(engine: ^Engine) {
	transforms := (^GpuTransform)(backend.buffer_mapped_ptr(current_frame_data(engine).transforms_buffer))
	for &instance, i in engine.scene.instances.values {
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
	shadow_pipeline := get_pipeline(&engine.pipeline_registry, .Shadow_Directional if directional else .Shadow)

	frame_idx := current_frame_res_index(engine)
	backend.pipeline_bind(cmd, shadow_pipeline, {engine.texture_system.descriptor.sets[frame_idx]})
	backend.cmd_set_depth_bias(cmd, 1.25, 0, 1.75)

	frame := current_frame_data(engine)

	frustum := frustum_from_view_proj(view_proj)

	for &instance, slot_i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(slot_i)) do continue
		if !instance.casts_shadow do continue

		model := &pool_get(&engine.model_system.models, instance.model)^

		// Directional casters in front of the cascade's near plane are depth-clamped, not clipped.
		if !volume_is_on_frustum(frustum, model.bounds, instance.transform, skip_near = directional) {
			continue
		}

		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend do continue
			if !aabb_is_on_frustum(frustum, mesh.bounds, instance.transform, skip_near = directional) do continue

			pc := ShadowPushConstants {
				scene_data       = frame.scene_data_buffer.ptr,
				vertex_buffer    = mesh.vertex_buffer.ptr,
				material_buffer  = engine.material_system.buffer.ptr,
				transform_buffer = frame.transforms_buffer.ptr,
				view_proj        = view_proj,
				instance_index   = u32(slot_i),
				light_type       = light_type,
				light_index      = light_i,
				material_index   = u32(mesh.material.index),
			}
			backend.pipeline_push(cmd, shadow_pipeline, {.Vertex, .Fragment}, &pc, index = 1)
			backend.cmd_draw_indexed(cmd, mesh.index_buffer.buffer, mesh.index_count)
			stats_count_draw(engine, u64(mesh.index_count / 3))
		}
	}
}

draw_meshes :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	mesh_pipeline := get_pipeline(&engine.pipeline_registry, .Mesh)

	frame_idx := current_frame_res_index(engine)
	sets := [2]backend.DescriptorSetHandle {
		engine.texture_system.descriptor.sets[frame_idx],
		engine.global_descriptor.sets[frame_idx],
	}
	backend.pipeline_bind(cmd, mesh_pipeline, sets[:])
	backend.pipeline_set_depth_write(cmd, mesh_pipeline, true)
	frame := current_frame_data(engine)

	active_camera := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	frustum := frustum_create_from_camera(
		active_camera,
		f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height),
	)

	draw_instance :: proc(
		engine: ^Engine,
		cmd: backend.RenderEncoder,
		pipeline: backend.Pipeline,
		frustum: Frustum,
		i: int,
		blend: bool,
	) {
		instance := &engine.scene.instances.values[i]
		model := pool_get(&engine.model_system.models, instance.model)

		frame := current_frame_data(engine)
		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if (mat.alpha_mode == .Blend) != blend do continue
			if !aabb_is_on_frustum(frustum, mesh.bounds, instance.transform) {
				engine.stats.counters.meshes_culled += 1
				continue
			}

			pc := PushConstants {
				scene_data       = frame.scene_data_buffer.ptr,
				vertex_buffer    = mesh.vertex_buffer.ptr,
				material_buffer  = engine.material_system.buffer.ptr,
				transform_buffer = frame.transforms_buffer.ptr,
				material_index   = u32(mesh.material.index),
				instance_index   = u32(i),
			}
			backend.pipeline_push(cmd, pipeline, {.Vertex, .Fragment}, &pc, index = 1)
			backend.cmd_draw_indexed(cmd, mesh.index_buffer.buffer, mesh.index_count)
			stats_count_draw(engine, u64(mesh.index_count / 3))
		}
	}

	TransparentEntry :: struct {
		index: int,
		dist:  f32,
	}
	transparent := make([dynamic]TransparentEntry, context.temp_allocator)

	// Cull per instance by bounding sphere, then per mesh by AABB inside draw_instance. Opaque/mask
	// meshes draw now; blended ones are queued.
	for &instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(i)) do continue
		model := pool_get(&engine.model_system.models, instance.model)
		if !volume_is_on_frustum(frustum, model.bounds, instance.transform) do continue
		engine.stats.counters.instances_drawn += 1

		has_opaque, has_blend: bool
		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend {
				has_blend = true
			} else {
				has_opaque = true
			}
		}

		if has_opaque do draw_instance(engine, cmd, mesh_pipeline, frustum, i, false)
		if has_blend {
			dist := linalg.length(instance.transform.translation - active_camera.position)
			append(&transparent, TransparentEntry{index = i, dist = dist})
		}
	}

	// transparent: back-to-front
	slice.sort_by(transparent[:], proc(a, b: TransparentEntry) -> bool {return a.dist > b.dist})
	backend.pipeline_set_depth_write(cmd, mesh_pipeline, false)
	for entry in transparent {
		draw_instance(engine, cmd, mesh_pipeline, frustum, entry.index, true)
	}
}

set_skybox_texture :: proc(engine: ^Engine, handle: TextureHandle) {
	// The global set isn't update-after-bind and this writes every frame's copy, so no
	// in-flight frame may be using it.
	backend.device_wait_idle(&engine.vk_ctx)
	t := pool_get(&engine.texture_system.textures, handle)
	sampler := engine.texture_system.samplers[SAMPLER_LINEAR_REPEAT]
	backend.descriptor_write_image_view(&engine.vk_ctx, &engine.global_descriptor, 2, &t.gpu, sampler)
}

// Renders every active light's shadow maps. Each atlas is transitioned as a whole (all layers,
// used or not) so the mesh pass always samples it in the layout the descriptor expects.
draw_shadow_maps :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	scene_data := (^SceneData)(backend.buffer_mapped_ptr(current_frame_data(engine).scene_data_buffer))
	dir_count := min(int(engine.scene.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	spot_count := min(int(engine.scene.spot_light_count), MAX_SPOT_LIGHTS)
	point_count := min(int(engine.scene.point_light_count), MAX_POINT_LIGHTS)

	// Masked-off or disabled shadows aren't sampled, so skip rendering them. Cached maps stay
	// valid and are re-checked when the light is enabled again.
	settings := &engine.debug_settings
	shadows_on := settings.disable_shadows == 0
	if !shadows_on || settings.light_mask & u32(LightMask.Directional) == 0 do dir_count = 0
	if !shadows_on || settings.light_mask & u32(LightMask.Spot) == 0 do spot_count = 0
	if !shadows_on || settings.light_mask & u32(LightMask.Point) == 0 do point_count = 0

	// Transitions run even when every pass is skipped: Depth_Read -> Depth_Write keeps the
	// contents, and the atlases must end in Depth_Read for the main pass.

	// 2D atlas: directional cascades first, then spot lights from SPOT_SHADOW_SLOT_BASE
	atlas_2d := &engine.shadow_2d_atlas
	scope_2d := gpu_scope_begin(engine, cmd, "shadow 2d")
	shadow_atlas_transition(cmd, atlas_2d, .Depth_Write, MAX_SHADOW_2D_SLOTS)
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
	shadow_atlas_transition(cmd, atlas_2d, .Depth_Read, MAX_SHADOW_2D_SLOTS)
	gpu_scope_end(engine, cmd, scope_2d)

	// cube atlas: 6 faces per point light
	atlas_cube := &engine.shadow_atlas
	scope_cube := gpu_scope_begin(engine, cmd, "shadow point")
	defer gpu_scope_end(engine, cmd, scope_cube)
	shadow_atlas_transition(cmd, atlas_cube, .Depth_Write, MAX_POINT_LIGHTS * 6)
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
	shadow_atlas_transition(cmd, atlas_cube, .Depth_Read, MAX_POINT_LIGHTS * 6)
}

// Renders one atlas layer. The atlas must already be in .Depth_Write (see shadow_atlas_transition).
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
		backend.PassConfig {
			depth = {image = &atlas.gpu, layer = layer},
			load_op = .Clear,
			store_depth = true,
			skip_depth_transition = true,
		},
	)
	engine.stats.counters.shadow_views += 1
	draw_shadow(engine, encoder, light_type, light_index, view_proj)
	backend.end_render_pass(encoder)
}

draw_skybox :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Skybox)
	skybox_frame_idx := current_frame_res_index(engine)
	backend.pipeline_bind(cmd, pipeline, {engine.global_descriptor.sets[skybox_frame_idx]})
	pc := SkyboxPushConstants {
		scene_data = current_frame_data(engine).scene_data_buffer.ptr,
	}
	backend.pipeline_push(cmd, pipeline, {.Vertex, .Fragment}, &pc)
	backend.cmd_draw(cmd)
	stats_count_draw(engine)
}

draw_ui :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	frame_idx := current_frame_res_index(engine)
	sets := [2]backend.DescriptorSetHandle {
		engine.texture_system.descriptor.sets[frame_idx],
		engine.global_descriptor.sets[frame_idx],
	}
	pipeline := get_pipeline(&engine.pipeline_registry, .UI)
	backend.pipeline_bind(cmd, pipeline, sets[:])
	ui_renderer_flush(engine, cmd)
}

draw_scene :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	if engine.debug_settings.particles {
		scope := gpu_scope_begin(engine, cmd, "particles")
		dispatch_particles(engine, cmd)
		gpu_scope_end(engine, cmd, scope)
	}

	draw_shadow_maps(engine, cmd)

	main_scope := gpu_scope_begin(engine, cmd, "main")
	{
		encoder := backend.begin_render_pass(
			&engine.vk_ctx,
			cmd,
			backend.PassConfig {
				color = {image = &engine.render_targets.color},
				resolve = {image = &engine.render_targets.hdr},
				depth = {image = &engine.render_targets.depth},
				clear_color = {0.1, 0.1, 0.1, 1},
				load_op = .Clear,
			},
		)
		draw_meshes(engine, encoder)
		draw_skybox(engine, encoder)
		if engine.debug_settings.particles do draw_particles(engine, encoder)
		line_renderer_flush(engine, encoder)
		backend.end_render_pass(encoder)
	}
	gpu_scope_end(engine, cmd, main_scope)

	bloom_scope := gpu_scope_begin(engine, cmd, "bloom")
	dispatch_bloom(engine, cmd)
	gpu_scope_end(engine, cmd, bloom_scope)

	tonemap_scope := gpu_scope_begin(engine, cmd, "tonemap")
	dispatch_tonemap(engine, cmd)
	gpu_scope_end(engine, cmd, tonemap_scope)

	overlay_scope := gpu_scope_begin(engine, cmd, "overlay")
	defer gpu_scope_end(engine, cmd, overlay_scope)
	debug_view_flush(engine, cmd)

	{
		encoder := backend.begin_render_pass(
			&engine.vk_ctx,
			cmd,
			backend.PassConfig{color = {image = &engine.render_targets.draw}, load_op = .Load},
		)
		draw_ui(engine, encoder)
		backend.end_render_pass(encoder)
	}
}

record_command_buffer :: proc(engine: ^Engine) -> backend.CommandBuffer {
	current_frame_sync := backend.current_frame_sync(&engine.vk_ctx, engine.frame_index)
	cmd := backend.frame_command_buffer_begin(&engine.vk_ctx, current_frame_sync)

	backend.cmd_begin_recording(&engine.vk_ctx, cmd, engine.frame_index)
	stats_record_begin(engine)
	defer stats_record_end(engine)
	gpu_profiler_reset(engine, cmd)

	frame_scope := gpu_scope_begin(engine, cmd, "frame")
	draw_scene(engine, cmd)
	backend.present_blit(&engine.vk_ctx, cmd, &engine.swapchain, &engine.render_targets.draw)
	gpu_scope_end(engine, cmd, frame_scope)

	backend.cmd_end_recording(cmd)
	return cmd
}

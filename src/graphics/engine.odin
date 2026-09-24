package graphics

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:slice"

import sdl "vendor:sdl3"

import "backend"

// eventually move this from init vulkan and actually make it like a init engine
engine_create :: proc(engine: ^Engine, window: ^sdl.Window, width, height: u32) -> (ok: bool) {
	engine.camera_system = camera_system_create({max_camera_count = 10})
	engine.scene.active_camera_name = DEFAULT_CAMERA_NAME
	engine.debug_settings.light_mask = LIGHT_MASK_ALL
	frame_dump_init(engine)
	debug_env_init(engine)
	engine.scene.ambient_light = AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.03,
	}

	pool := backend.autorelease_pool_begin()
	defer backend.autorelease_pool_end(pool)

	vk_ctx := &engine.vk_ctx
	backend.context_init(vk_ctx, window)
	backend.upload_pool_create(vk_ctx)

	engine.swapchain = backend.swapchain_create(vk_ctx, width, height)
	engine.swapchain.render_targets = backend.render_targets_create(
		vk_ctx,
		engine.swapchain.extent,
		engine.vk_ctx.msaa_samples,
	)

	// macos (Moltenvk) wont support what we set for MAX_TEXTURES
	max_bindless_textures := min(MAX_TEXTURES, vk_ctx.max_bindless_samplers_per_stage - 3)

	shader_system_create(engine, max_bindless_textures) or_return
	shadow_handle := shader_load(engine, "shadow", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	ui_handle := shader_load(engine, "ui", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	mesh_handle := shader_load(engine, "mesh", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	particle_handle := shader_load(engine, "particle", {VERTEX_ENTRY, FRAGMENT_MAIN, COMPUTE_MAIN}) or_return
	skybox_handle := shader_load(engine, "skybox", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	debug_view_handle := shader_load(engine, "debug_view", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return

	backend.frame_sync_create(vk_ctx)
	frame_data_create(engine)

	texture_system_create(engine, {max_textures_count = max_bindless_textures})
	material_system_create(engine, {max_material_count = MAX_MATERIALS})
	create_model_system(engine)

	global_resources_create(engine)

	register_shadow_pipelines(engine, shadow_handle)
	register_ui_pipeline(engine, ui_handle)
	register_mesh_pipeline(engine, mesh_handle)
	register_particle_pipelines(engine, particle_handle)
	register_skybox_pipeline(engine, skybox_handle)
	register_debug_view_pipeline(engine, debug_view_handle)

	line_renderer_create(engine) or_return
	ui_renderer_create(engine)

	return true
}

window_backend_flags :: proc() -> sdl.WindowFlags {
	when backend.VEIL_METAL {
		return {.METAL}
	} else when backend.VEIL_VULKAN {
		return {.VULKAN}
	}
}

global_resources_create :: proc(engine: ^Engine) {
	vk_ctx := &engine.vk_ctx

	engine.global_descriptor = backend.descriptor_set_create_sampler_array(vk_ctx, 3)
	engine.shadow_atlas = shadow_atlas_create(vk_ctx, SHADOW_MAP_SIZE, MAX_POINT_LIGHTS * 6, cube = true)
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
}

engine_destroy :: proc(self: ^Engine) {
	backend.device_wait_idle(&self.vk_ctx)

	camera_system_destroy(&self.camera_system)
	frame_dump_destroy(self)
	texture_system_destroy(self)
	destroy_model_system(self)
	material_system_destroy(self)

	backend.descriptor_set_destroy(&self.vk_ctx, &self.global_descriptor)
	shadow_atlas_destroy(&self.vk_ctx, &self.shadow_atlas)
	shadow_atlas_destroy(&self.vk_ctx, &self.shadow_2d_atlas)

	line_renderer_destroy(self)
	ui_renderer_destroy(self)

	destroy_pipeline_registry(&self.vk_ctx, &self.pipeline_registry)

	shader_system_destroy(self)

	frame_data_destroy(self)
	backend.frame_sync_destroy(&self.vk_ctx)
	backend.swapchain_destroy(&self.vk_ctx, &self.swapchain)

	backend.context_destroy(&self.vk_ctx)
}

engine_render :: proc(app: ^App, delta_time: f32) {
	// A minimized window has no drawable pixels; keep the old swapchain until it returns.
	// Still drain per-frame debug batches so producers that keep running (e.g. gizmo
	// drawing) don't overflow them while no frame is being rendered.
	if app.width == 0 || app.height == 0 {
		line_renderer_clear(&app.engine)
		ui_renderer_clear(&app.engine)
		return
	}

	pool := backend.autorelease_pool_begin()
	defer backend.autorelease_pool_end(pool)

	app.engine.time_info.delta_time = delta_time
	app.engine.time_info.time += delta_time
	app.engine.time_info.frame_count += 1

	// recreate swapchain
	if app.engine.swapchain.require_recreate {
		backend.device_wait_idle(&app.engine.vk_ctx)
		backend.swapchain_destroy(&app.engine.vk_ctx, &app.engine.swapchain)
		app.engine.swapchain = backend.swapchain_create(&app.engine.vk_ctx, app.width, app.height)
		app.engine.swapchain.render_targets = backend.render_targets_create(
			&app.engine.vk_ctx,
			app.engine.swapchain.extent,
			app.engine.vk_ctx.msaa_samples,
		)
		app.engine.swapchain.require_recreate = false
	}

	backend.frame_wait_before_render(&app.engine.vk_ctx, app.engine.frame_index)

	current_frame_sync := backend.current_frame_sync(&app.engine.vk_ctx, app.engine.frame_index)
	current_frame_data := current_frame_data(&app.engine)

	// NOTE: purely chance, but your frame resources and swapchain count can be different
	// in our case, it was chance they are both two.
	acquire_result := backend.swapchain_acquire_next_image(
		&app.engine.vk_ctx,
		&app.engine.swapchain,
		current_frame_sync,
	)

	if acquire_result == .NotReady {
		// Nothing to draw into yet. Drain the debug batches like the minimized path does,
		// otherwise producers keep appending while we skip frames.
		line_renderer_clear(&app.engine)
		ui_renderer_clear(&app.engine)
		return
	}

	if acquire_result == .OutOfDate {
		app.engine.swapchain.require_recreate = true
		line_renderer_clear(&app.engine)
		ui_renderer_clear(&app.engine)
		return
	} else if acquire_result == .Suboptimal {
		app.engine.swapchain.require_recreate = true
	}

	scene_data_buffer_update(&app.engine)
	update_transforms_buffer(&app.engine)
	shader_poll_hotreload(&app.engine)

	cmd := record_command_buffer(&app.engine)

	signal_value := app.engine.frame_index + 1
	backend.queue_submit_frame(&app.engine.vk_ctx, cmd, &app.engine.swapchain, current_frame_sync, signal_value)

	present_result := backend.queue_present_frame(&app.engine.vk_ctx, cmd, &app.engine.swapchain, current_frame_sync)

	if present_result == .OutOfDate {
		app.engine.swapchain.require_recreate = true
	} else if present_result == .Suboptimal {
		app.engine.swapchain.require_recreate = true
	} else if present_result == .Error {
		log.errorf("queue_present_frame failed")
	}

	if app.engine.frame_dump.enabled {
		backend.device_wait_idle(&app.engine.vk_ctx)
		pick_test_run(&app.engine)
		if frame_dump_capture(&app.engine) {
			quit := sdl.Event {
				type = .QUIT,
			}
			_ = sdl.PushEvent(&quit)
		}
	}

	app.engine.frame_index += 1
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
	backend.pipeline_bind_compute(encoder, pipeline)
	backend.pipeline_push_compute(encoder, pipeline, &compute_pc)
	backend.cmd_dispatch(encoder, PARTICLE_COUNT / 256, 1, 1)
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
}

CUBE_FACE_DIRS := [6]struct {
	target, up: Vec3,
} {
	{{1, 0, 0}, {0, -1, 0}},
	{{-1, 0, 0}, {0, -1, 0}},
	{{0, 1, 0}, {0, 0, 1}},
	{{0, -1, 0}, {0, 0, -1}},
	{{0, 0, 1}, {0, -1, 0}},
	{{0, 0, -1}, {0, -1, 0}},
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
	shadow_pipeline := get_pipeline(&engine.pipeline_registry, .Shadow)

	frame_idx := current_frame_res_index(engine)
	backend.pipeline_bind(cmd, shadow_pipeline, {engine.texture_system.descriptor.sets[frame_idx]})
	backend.cmd_set_depth_bias(cmd, 1.25, 0, 1.75)

	frame := current_frame_data(engine)
	backend.cmd_use_buffer(cmd, frame.scene_data_buffer)
	backend.cmd_use_buffer(cmd, frame.transforms_buffer)
	backend.cmd_use_buffer(cmd, engine.material_system.buffer)

	frustum := frustum_from_view_proj(view_proj)

	for &instance, slot_i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(slot_i)) do continue
		if !instance.casts_shadow do continue

		model := &pool_get(&engine.model_system.models, instance.model)^

		if !volume_is_on_frustum(frustum, model.bounds, instance.transform) {
			continue
		}

		for &mesh in model.meshes {
			backend.cmd_use_buffer(cmd, mesh.vertex_buffer)
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend do continue

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
		}
	}
}

draw_meshes :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	engine.drawn_instance_count = 0

	mesh_pipeline := get_pipeline(&engine.pipeline_registry, .Mesh)

	frame_idx := current_frame_res_index(engine)
	sets := [2]backend.DescriptorSetHandle {
		engine.texture_system.descriptor.sets[frame_idx],
		engine.global_descriptor.sets[frame_idx],
	}
	backend.pipeline_bind(cmd, mesh_pipeline, sets[:])
	backend.pipeline_set_depth_write(cmd, mesh_pipeline, true)
	frame := current_frame_data(engine)
	backend.cmd_use_buffer(cmd, frame.scene_data_buffer)
	backend.cmd_use_buffer(cmd, frame.transforms_buffer)
	backend.cmd_use_buffer(cmd, engine.material_system.buffer)

	active_camera := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	frustum := frustum_create_from_camera(
		active_camera,
		f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height),
	)

	draw_instance :: proc(
		engine: ^Engine,
		cmd: backend.RenderEncoder,
		pipeline: backend.Pipeline,
		i: int,
		blend: bool,
	) {
		instance := &engine.scene.instances.values[i]
		model := pool_get(&engine.model_system.models, instance.model)

		frame := current_frame_data(engine)
		for &mesh in model.meshes {
			backend.cmd_use_buffer(cmd, mesh.vertex_buffer)
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if (mat.alpha_mode == .Blend) != blend do continue

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
		}
	}

	TransparentEntry :: struct {
		index: int,
		dist:  f32,
	}
	transparent := make([dynamic]TransparentEntry, context.temp_allocator)

	// Cull once per instance, draw its opaque/mask meshes now, and queue its blended meshes.
	for &instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(i)) do continue
		model := pool_get(&engine.model_system.models, instance.model)
		if !volume_is_on_frustum(frustum, model.bounds, instance.transform) do continue
		engine.drawn_instance_count += 1

		has_opaque, has_blend: bool
		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend {
				has_blend = true
			} else {
				has_opaque = true
			}
		}

		if has_opaque do draw_instance(engine, cmd, mesh_pipeline, i, false)
		if has_blend {
			dist := linalg.length(instance.transform.translation - active_camera.position)
			append(&transparent, TransparentEntry{index = i, dist = dist})
		}
	}

	// transparent: back-to-front
	slice.sort_by(transparent[:], proc(a, b: TransparentEntry) -> bool {return a.dist > b.dist})
	backend.pipeline_set_depth_write(cmd, mesh_pipeline, false)
	for entry in transparent {
		draw_instance(engine, cmd, mesh_pipeline, entry.index, true)
	}
}

set_skybox_texture :: proc(engine: ^Engine, handle: TextureHandle) {
	// The global set isn't update-after-bind and this writes every frame's copy, so no
	// in-flight frame may be using it.
	backend.device_wait_idle(&engine.vk_ctx)
	t := pool_get(&engine.texture_system.textures, handle)
	backend.descriptor_write_image_view(&engine.vk_ctx, &engine.global_descriptor, 2, &t.gpu, t.sampler)
}

draw_skybox :: proc(engine: ^Engine, cmd: backend.RenderEncoder) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Skybox)
	skybox_frame_idx := current_frame_res_index(engine)
	backend.pipeline_bind(cmd, pipeline, {engine.global_descriptor.sets[skybox_frame_idx]})
	backend.descriptor_bind_image(cmd, engine.global_descriptor.sets[skybox_frame_idx], 2, 0)
	backend.cmd_use_buffer(cmd, current_frame_data(engine).scene_data_buffer)
	pc := SkyboxPushConstants {
		scene_data = current_frame_data(engine).scene_data_buffer.ptr,
	}
	backend.pipeline_push(cmd, pipeline, {.Vertex, .Fragment}, &pc)
	backend.cmd_draw(cmd)
}

// Draws a single texture, shadow-cube face, or directional shadow slice into a screen-space
// rect. Reusable for shadow-atlas debugging as well as inspecting any bindless model texture.
draw_debug_view :: proc(engine: ^Engine, cmd: backend.RenderEncoder, pc: DebugViewPushConstants, rect: Rect2D) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Debug_View)
	frame_idx := current_frame_res_index(engine)
	sets := [2]backend.DescriptorSetHandle {
		engine.texture_system.descriptor.sets[frame_idx],
		engine.global_descriptor.sets[frame_idx],
	}
	backend.pipeline_bind(cmd, pipeline, sets[:])

	backend.pipeline_set_viewport(cmd, f32(rect.extent.x), f32(rect.extent.y), f32(rect.offset.x), f32(rect.offset.y))
	backend.pipeline_set_scissor(cmd, rect.extent.x, rect.extent.y, rect.offset.x, rect.offset.y)

	pc := pc
	backend.pipeline_push(cmd, pipeline, {.Fragment}, &pc, index = 1)
	backend.cmd_draw(cmd)
}

draw_debug_shadow_map :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	DEBUG_SIZE :: 128

	encoder := backend.begin_render_pass(
		&engine.vk_ctx,
		cmd,
		backend.PassConfig{color = {image = &engine.swapchain.render_targets.draw}, load_op = .Load},
	)

	// 6 point-light cube faces, then the first directional light's cascades, then the first spot light.
	tile_count := 6 + SHADOW_MAP_CASCADE_COUNT + 1
	for i in 0 ..< tile_count {
		offset_x := u32(i) * DEBUG_SIZE
		if offset_x >= u32(engine.swapchain.extent.width) do break
		rect := Rect2D {
			offset = {i32(offset_x), 0},
			extent = {min(DEBUG_SIZE, u32(engine.swapchain.extent.width) - offset_x), DEBUG_SIZE},
		}
		pc: DebugViewPushConstants
		if i < 6 {
			pc = {
				mode  = .Shadow_Cube_Face,
				index = 0,
				face  = u32(i),
			}
		} else if i < 6 + SHADOW_MAP_CASCADE_COUNT {
			// cascades of directional light 0 only
			cascade := i - 6
			pc = {
				mode  = .Shadow_2D,
				index = u32(cascade),
			}
		} else {
			// first spot light's slot in the 2D shadow atlas
			pc = {
				mode  = .Shadow_2D,
				index = MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT,
			}
		}
		draw_debug_view(engine, encoder, pc, rect)
	}

	backend.end_render_pass(encoder)
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
	// dispatch_particles(engine, cmd)

	shadow_light_count := min(int(engine.scene.point_light_count), MAX_POINT_LIGHTS)
	dir_shadow_light_count := min(int(engine.scene.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	spot_shadow_light_count := min(int(engine.scene.spot_light_count), MAX_SPOT_LIGHTS)

	// 2D shadow maps (directional lights first, then spot lights)
	backend.image_barrier(
		cmd,
		&engine.shadow_2d_atlas.gpu,
		.Depth_Write,
		backend.ImageAspectFlags{.Depth},
		layer_count = MAX_SHADOW_2D_SLOTS,
	)

	for i in 0 ..< dir_shadow_light_count {
		for cascade in 0 ..< SHADOW_MAP_CASCADE_COUNT {
			slot := u32(i * SHADOW_MAP_CASCADE_COUNT + cascade)
			encoder := backend.begin_render_pass(
				&engine.vk_ctx,
				cmd,
				backend.PassConfig {
					depth = {image = &engine.shadow_2d_atlas.gpu, layer = slot},
					load_op = .Clear,
					store_depth = true,
					skip_depth_transition = true,
				},
			)
			scene_data := (^SceneData)(backend.buffer_mapped_ptr(current_frame_data(engine).scene_data_buffer))
			draw_shadow(engine, encoder, .Directional, slot, scene_data.shadow_2d_view_proj[slot])
			backend.end_render_pass(encoder)
		}
	}
	for i in 0 ..< spot_shadow_light_count {
		encoder := backend.begin_render_pass(
			&engine.vk_ctx,
			cmd,
			backend.PassConfig {
				depth = {
					image = &engine.shadow_2d_atlas.gpu,
					layer = u32((MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + i),
				},
				load_op = .Clear,
				store_depth = true,
				skip_depth_transition = true,
			},
		)
		scene_data := (^SceneData)(backend.buffer_mapped_ptr(current_frame_data(engine).scene_data_buffer))
		slot := u32((MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + i)
		draw_shadow(engine, encoder, .Spot, u32(i), scene_data.shadow_2d_view_proj[slot])
		backend.end_render_pass(encoder)
	}
	// Transition 2D shadow atlas to read-only for the mesh pass
	backend.image_barrier(
		cmd,
		&engine.shadow_2d_atlas.gpu,
		.Depth_Read,
		backend.ImageAspectFlags{.Depth},
		layer_count = MAX_SHADOW_2D_SLOTS,
	)

	// Always transition all MAX_POINT_LIGHTS*6 layers so unused layers are in the
	// expected layout when the mesh pass samples the descriptor.
	backend.image_barrier(
		cmd,
		&engine.shadow_atlas.gpu,
		.Depth_Write,
		backend.ImageAspectFlags{.Depth},
		layer_count = MAX_POINT_LIGHTS * 6,
	)
	for light_i in 0 ..< shadow_light_count {
		for face_i in 0 ..< 6 {
			view_i := light_i * 6 + face_i
			encoder := backend.begin_render_pass(
				&engine.vk_ctx,
				cmd,
				backend.PassConfig {
					depth = {image = &engine.shadow_atlas.gpu, layer = u32(view_i)},
					load_op = .Clear,
					store_depth = true,
					skip_depth_transition = true,
				},
			)
			scene_data := (^SceneData)(backend.buffer_mapped_ptr(current_frame_data(engine).scene_data_buffer))
			draw_shadow(engine, encoder, .Point, u32(light_i), scene_data.point_light_view_proj[light_i][face_i])
			backend.end_render_pass(encoder)
		}
	}

	backend.image_barrier(
		cmd,
		&engine.shadow_atlas.gpu,
		.Depth_Read,
		backend.ImageAspectFlags{.Depth},
		layer_count = MAX_POINT_LIGHTS * 6,
	)

	{
		encoder := backend.begin_render_pass(
			&engine.vk_ctx,
			cmd,
			backend.PassConfig {
				color = {image = &engine.swapchain.render_targets.color},
				resolve = {image = &engine.swapchain.render_targets.draw},
				depth = {image = &engine.swapchain.render_targets.depth},
				clear_color = {0.1, 0.1, 0.1, 1},
				load_op = .Clear,
			},
		)
		draw_meshes(engine, encoder)
		draw_skybox(engine, encoder)
		// draw_particles(engine, encoder)
		line_renderer_flush(engine, encoder)
		backend.end_render_pass(encoder)
	}

	draw_debug_shadow_map(engine, cmd)

	{
		encoder := backend.begin_render_pass(
			&engine.vk_ctx,
			cmd,
			backend.PassConfig{color = {image = &engine.swapchain.render_targets.draw}, load_op = .Load},
		)
		draw_ui(engine, encoder)
		backend.end_render_pass(encoder)
	}
}

record_command_buffer :: proc(engine: ^Engine) -> backend.CommandBuffer {
	current_frame_sync := backend.current_frame_sync(&engine.vk_ctx, engine.frame_index)
	cmd := backend.frame_command_buffer_begin(&engine.vk_ctx, current_frame_sync)

	backend.cmd_begin_recording(&engine.vk_ctx, cmd, engine.frame_index)

	draw_scene(engine, cmd)

	backend.present_blit(&engine.vk_ctx, cmd, &engine.swapchain)

	backend.cmd_end_recording(cmd)
	return cmd
}

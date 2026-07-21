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
	engine.scene.ambient_light = AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.03,
	}

	vk_ctx := &engine.vk_ctx
	backend.context_init(vk_ctx, window)
	backend.upload_pool_create(vk_ctx)

	engine.swapchain = backend.swapchain_create(vk_ctx, width, height)
	engine.swapchain.render_targets = backend.render_targets_create(
		vk_ctx,
		engine.swapchain.extent,
		engine.vk_ctx.msaa_samples,
	)

	shader_system_create(engine) or_return
	shadow_handle := shader_load(engine, "shadow", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	ui_handle := shader_load(engine, "ui", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	mesh_handle := shader_load(engine, "mesh", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	particle_handle := shader_load(engine, "particle", {VERTEX_ENTRY, FRAGMENT_MAIN, COMPUTE_MAIN}) or_return
	skybox_handle := shader_load(engine, "skybox", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	debug_view_handle := shader_load(engine, "debug_view", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return

	backend.frame_sync_create(vk_ctx)
	frame_data_create(engine)

	// macos (Moltenvk) wont support what we set for MAX_TEXTURES
	max_bindless_textures := min(MAX_TEXTURES, vk_ctx.max_bindless_samplers_per_stage - 3)
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

	return true
}

global_resources_create :: proc(engine: ^Engine) {
	vk_ctx := &engine.vk_ctx

	engine.global_descriptor = backend.descriptor_set_create(
		vk_ctx,
		{
			{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
			{binding = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
			{binding = 2, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		},
		count = backend.MAX_FRAMES_IN_FLIGHT,
	)
	engine.shadow_atlas = shadow_atlas_create(vk_ctx, SHADOW_MAP_SIZE, MAX_POINT_LIGHTS * 6, cube = true)
	backend.descriptor_write_image_view(
		vk_ctx,
		&engine.global_descriptor,
		0,
		engine.shadow_atlas.image_view,
		engine.shadow_atlas.sampler,
		.Depth_Read,
	)
	engine.shadow_2d_atlas = shadow_atlas_create(vk_ctx, SHADOW_MAP_SIZE, MAX_SHADOW_2D_SLOTS, cube = false)
	backend.descriptor_write_image_view(
		vk_ctx,
		&engine.global_descriptor,
		1,
		engine.shadow_2d_atlas.image_view,
		engine.shadow_2d_atlas.sampler,
		.Depth_Read,
	)
}

engine_destroy :: proc(self: ^Engine) {
	backend.device_wait_idle(&self.vk_ctx)

	camera_system_destroy(&self.camera_system)
	texture_system_destroy(self)
	destroy_model_system(self)
	material_system_destroy(self)

	backend.descriptor_set_destroy(&self.vk_ctx, &self.global_descriptor)
	shadow_atlas_destroy(&self.vk_ctx, &self.shadow_atlas)
	shadow_atlas_destroy(&self.vk_ctx, &self.shadow_2d_atlas)

	line_renderer_destroy(self, &self.line_renderer)

	destroy_pipeline_registry(&self.vk_ctx, &self.pipeline_registry)

	shader_system_destroy(self)

	frame_data_destroy(self)
	backend.frame_sync_destroy(&self.vk_ctx)
	backend.swapchain_destroy(&self.vk_ctx, &self.swapchain)

	backend.context_destroy(&self.vk_ctx)
}

engine_render :: proc(app: ^App, delta_time: f32) {
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

	next_signal_value := app.engine.frame_index + 1
	backend.frame_wait_before_render(&app.engine.vk_ctx, next_signal_value)

	current_frame_sync := backend.current_frame_sync(&app.engine.vk_ctx, app.engine.frame_index)
	current_frame_data := current_frame_data(&app.engine)

	// NOTE: purely chance, but your frame resources and swapchain count can be different
	// in our case, it was chance they are both two.
	acquire_result, image_index := backend.swapchain_acquire_next_image(
		&app.engine.vk_ctx,
		&app.engine.swapchain,
		current_frame_sync.image_acquired_semaphore,
	)
	app.engine.current_image_index = image_index

	if acquire_result == .OutOfDate {
		app.engine.swapchain.require_recreate = true
		return
	} else if acquire_result == .Suboptimal {
		app.engine.swapchain.require_recreate = true
	}

	scene_data_buffer_update(&app.engine)
	update_transforms_buffer(&app.engine)
	shader_poll_hotreload(&app.engine)

	record_command_buffer(&app.engine)

	cmd := current_frame_sync.command_buffer
	signal_value := next_signal_value

	backend.queue_submit_frame(&app.engine.vk_ctx, cmd, current_frame_sync, signal_value)

	present_result := backend.queue_present_frame(
		&app.engine.vk_ctx,
		app.engine.swapchain.handle,
		current_frame_sync.render_complete_semaphore,
		app.engine.current_image_index,
	)

	if present_result == .OutOfDate {
		app.engine.swapchain.require_recreate = true
	} else if present_result == .Suboptimal {
		app.engine.swapchain.require_recreate = true
	} else if present_result == .Error {
		log.errorf("queue_present_frame failed")
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
	backend.pipeline_bind(cmd, pipeline, .COMPUTE)
	backend.pipeline_push(cmd, pipeline, {.COMPUTE}, &compute_pc)
	backend.cmd_dispatch(cmd, PARTICLE_COUNT / 256, 1, 1)
	backend.cmd_pipeline_barrier_memory(cmd, {.COMPUTE_SHADER}, {.VERTEX_SHADER}, {.SHADER_WRITE}, {.SHADER_READ})
}

draw_particles :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Particle_Draw)

	frame_res_index := current_frame_res_index(engine)
	particle_pc := ParticlePushConstants {
		scene_data    = engine.frame_data[frame_res_index].scene_data_buffer.ptr,
		particles_out = engine.frame_data[frame_res_index].particle_buffer.ptr,
	}
	backend.pipeline_bind(cmd, pipeline)
	backend.pipeline_push(cmd, pipeline, {.VERTEX, .FRAGMENT}, &particle_pc)
	backend.cmd_draw(cmd, PARTICLE_COUNT)
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
	transforms := (^GpuTransform)(current_frame_data(engine).transforms_buffer.alloc_info.mapped_data)
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
	cmd: backend.CommandBuffer,
	light_type: ShadowLightType,
	light_i: u32,
	view_proj: Mat4x4,
) {
	shadow_pipeline := get_pipeline(&engine.pipeline_registry, .Shadow)

	backend.pipeline_bind(cmd, shadow_pipeline)
	backend.cmd_set_depth_bias(cmd, 1.25, 0, 1.75)

	frame := current_frame_data(engine)

	frustum := frustum_from_view_proj(view_proj)

	for &instance, slot_i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(slot_i)) do continue

		model := &pool_get(&engine.model_system.models, instance.model)^

		if !volume_is_on_frustum(frustum, model.bounds, instance.transform) {
			continue
		}

		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend do continue

			pc := ShadowPushConstants {
				scene_data       = frame.scene_data_buffer.ptr,
				vertex_buffer    = mesh.vertex_buffer.ptr,
				transform_buffer = frame.transforms_buffer.ptr,
				view_proj        = view_proj,
				instance_index   = u32(slot_i),
				light_type       = light_type,
				light_index      = light_i,
			}
			backend.pipeline_push(cmd, shadow_pipeline, {.VERTEX, .FRAGMENT}, &pc)
			backend.cmd_draw_indexed(cmd, mesh.index_buffer.buffer, mesh.index_count)
		}
	}
}

draw_meshes :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	engine.drawn_instance_count = 0

	mesh_pipeline := get_pipeline(&engine.pipeline_registry, .Mesh)

	frame_idx := current_frame_res_index(engine)
	sets := [2]backend.DescriptorSetHandle {
		engine.texture_system.descriptor.sets[frame_idx],
		engine.global_descriptor.sets[frame_idx],
	}
	backend.pipeline_bind(cmd, mesh_pipeline, .GRAPHICS, sets[:])

	active_camera := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	frustum := frustum_create_from_camera(
		active_camera,
		f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height),
	)

	draw_instance :: proc(engine: ^Engine, frustum: Frustum, cmd: backend.CommandBuffer, i: int, blend: bool) {
		instance := &engine.scene.instances.values[i]
		model := pool_get(&engine.model_system.models, instance.model)

		if !volume_is_on_frustum(frustum, model.bounds, instance.transform) {
			return
		}
		engine.drawn_instance_count += 1

		frame := current_frame_data(engine)
		for &mesh in model.meshes {
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
			backend.pipeline_push(cmd, get_pipeline(&engine.pipeline_registry, .Mesh), {.VERTEX, .FRAGMENT}, &pc)
			backend.cmd_draw_indexed(cmd, mesh.index_buffer.buffer, mesh.index_count)
		}
	}

	// opaque + mask
	for &instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(i)) do continue
		model := &pool_get(&engine.model_system.models, instance.model)^
		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend do continue
			draw_instance(engine, frustum, cmd, i, false)
			break
		}
	}

	// transparent — collect and sort back-to-front
	TransparentEntry :: struct {
		index: int,
		dist:  f32,
	}
	transparent := make([dynamic]TransparentEntry, context.temp_allocator)
	for &instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(i)) do continue
		model := &pool_get(&engine.model_system.models, instance.model)^
		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode != .Blend do continue
			pos := instance.transform.translation
			cam := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name).position
			dist := linalg.length(pos - cam)
			append(&transparent, TransparentEntry{index = i, dist = dist})
			break
		}
	}

	slice.sort_by(transparent[:], proc(a, b: TransparentEntry) -> bool {return a.dist > b.dist})
	for entry in transparent {
		draw_instance(engine, frustum, cmd, entry.index, true)
	}
}

set_skybox_texture :: proc(engine: ^Engine, handle: TextureHandle) {
	t := pool_get(&engine.texture_system.textures, handle)
	backend.descriptor_write_image_view(&engine.vk_ctx, &engine.global_descriptor, 2, t.image_view, t.sampler)
}

draw_skybox :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Skybox)
	skybox_frame_idx := current_frame_res_index(engine)
	backend.pipeline_bind(cmd, pipeline, .GRAPHICS, {engine.global_descriptor.sets[skybox_frame_idx]})
	pc := SkyboxPushConstants {
		scene_data = current_frame_data(engine).scene_data_buffer.ptr,
	}
	backend.pipeline_push(cmd, pipeline, {.VERTEX, .FRAGMENT}, &pc)
	backend.cmd_draw(cmd)
}

// Draws a single texture, shadow-cube face, or directional shadow slice into a screen-space
// rect. Reusable for shadow-atlas debugging as well as inspecting any bindless model texture.
draw_debug_view :: proc(engine: ^Engine, cmd: backend.CommandBuffer, pc: DebugViewPushConstants, rect: Rect2D) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Debug_View)
	frame_idx := current_frame_res_index(engine)
	sets := [2]backend.DescriptorSetHandle {
		engine.texture_system.descriptor.sets[frame_idx],
		engine.global_descriptor.sets[frame_idx],
	}
	backend.pipeline_bind(cmd, pipeline, .GRAPHICS, sets[:])

	backend.pipeline_set_viewport(cmd, f32(rect.extent.x), f32(rect.extent.y), f32(rect.offset.x), f32(rect.offset.y))
	backend.pipeline_set_scissor(cmd, rect.extent.x, rect.extent.y, rect.offset.x, rect.offset.y)

	pc := pc
	backend.pipeline_push(cmd, pipeline, {.FRAGMENT}, &pc)
	backend.cmd_draw(cmd)
}

draw_debug_shadow_map :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	DEBUG_SIZE :: 128

	begin_render_pass(
		engine,
		cmd,
		PassConfig{color = {image = &engine.swapchain.render_targets.draw}, load_op = .Load},
	)

	// 6 point-light cube faces, then the first directional light's cascades, then the first spot light.
	tile_count := 6 + SHADOW_MAP_CASCADE_COUNT + 1
	for i in 0 ..< tile_count {
		rect := Rect2D {
			offset = {i32(i) * DEBUG_SIZE, 0},
			extent = {DEBUG_SIZE, DEBUG_SIZE},
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
		draw_debug_view(engine, cmd, pc, rect)
	}

	end_render_pass(cmd)
}

draw_ui :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .UI)
	backend.pipeline_bind(cmd, pipeline)
	backend.cmd_draw(cmd, 6)
}

draw_scene :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	// dispatch_particles(engine, cmd)

	shadow_light_count := min(int(engine.scene.point_light_count), MAX_POINT_LIGHTS)
	dir_shadow_light_count := min(int(engine.scene.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	spot_shadow_light_count := min(int(engine.scene.spot_light_count), MAX_SPOT_LIGHTS)

	// 2D shadow maps (directional lights first, then spot lights)
	backend.image_barrier(
		cmd,
		engine.shadow_2d_atlas.image,
		.Undefined,
		.Depth_Write,
		{.DEPTH},
		layer_count = MAX_SHADOW_2D_SLOTS,
	)

	for i in 0 ..< dir_shadow_light_count {
		for cascade in 0 ..< SHADOW_MAP_CASCADE_COUNT {
			slot := u32(i * SHADOW_MAP_CASCADE_COUNT + cascade)
			begin_render_pass(
				engine,
				cmd,
				PassConfig {
					depth = {image = &engine.shadow_2d_atlas.gpu, layer = slot},
					load_op = .Clear,
					store_depth = true,
					skip_depth_transition = true,
				},
			)
			scene_data := (^SceneData)(current_frame_data(engine).scene_data_buffer.alloc_info.mapped_data)
			draw_shadow(engine, cmd, .Directional, slot, scene_data.shadow_2d_view_proj[slot])
			end_render_pass(cmd)
		}
	}
	for i in 0 ..< spot_shadow_light_count {
		begin_render_pass(
			engine,
			cmd,
			PassConfig {
				depth = {
					image = &engine.shadow_2d_atlas.gpu,
					layer = u32((MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + i),
				},
				load_op = .Clear,
				store_depth = true,
				skip_depth_transition = true,
			},
		)
		scene_data := (^SceneData)(current_frame_data(engine).scene_data_buffer.alloc_info.mapped_data)
		slot := u32((MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + i)
		draw_shadow(engine, cmd, .Spot, u32(i), scene_data.shadow_2d_view_proj[slot])
		end_render_pass(cmd)
	}
	// Transition 2D shadow atlas to read-only for the mesh pass
	backend.image_barrier(
		cmd,
		engine.shadow_2d_atlas.image,
		.Depth_Write,
		.Depth_Read,
		{.DEPTH},
		layer_count = MAX_SHADOW_2D_SLOTS,
	)

	// Always transition all MAX_POINT_LIGHTS*6 layers so unused layers are in the
	// expected layout when the mesh pass samples the descriptor.
	backend.image_barrier(
		cmd,
		engine.shadow_atlas.image,
		.Undefined,
		.Depth_Write,
		{.DEPTH},
		layer_count = MAX_POINT_LIGHTS * 6,
	)
	for light_i in 0 ..< shadow_light_count {
		for face_i in 0 ..< 6 {
			view_i := light_i * 6 + face_i
			begin_render_pass(
				engine,
				cmd,
				PassConfig {
					depth = {image = &engine.shadow_atlas.gpu, layer = u32(view_i)},
					load_op = .Clear,
					store_depth = true,
					skip_depth_transition = true,
				},
			)
			scene_data := (^SceneData)(current_frame_data(engine).scene_data_buffer.alloc_info.mapped_data)
			draw_shadow(engine, cmd, .Point, u32(light_i), scene_data.point_light_view_proj[light_i][face_i])
			end_render_pass(cmd)
		}
	}

	backend.image_barrier(
		cmd,
		engine.shadow_atlas.image,
		.Depth_Write,
		.Depth_Read,
		{.DEPTH},
		layer_count = MAX_POINT_LIGHTS * 6,
	)

	begin_render_pass(
		engine,
		cmd,
		PassConfig {
			color = {image = &engine.swapchain.render_targets.color},
			resolve = {image = &engine.swapchain.render_targets.draw},
			depth = {image = &engine.swapchain.render_targets.depth},
			clear_color = {0.1, 0.1, 0.1, 1},
			load_op = .Clear,
		},
	)
	draw_meshes(engine, cmd)
	draw_skybox(engine, cmd)
	// draw_particles(engine, cmd)
	end_render_pass(cmd)

	draw_debug_shadow_map(engine, cmd)

	// begin_render_pass(engine, cmd, PassConfig{color = {image = &engine.swapchain.draw_image}, load_op = .Load})
	// draw_ui(engine, cmd)
	// end_render_pass(cmd)
}

record_command_buffer :: proc(engine: ^Engine) {
	current_frame_sync := backend.current_frame_sync(&engine.vk_ctx, engine.frame_index)
	cmd := current_frame_sync.command_buffer

	backend.cmd_begin_recording(&engine.vk_ctx, cmd, engine.frame_index)

	draw_scene(engine, cmd)

	backend.image_barrier(cmd, engine.swapchain.render_targets.draw.image, .Color_Write, .Transfer_Src, {.COLOR})
	backend.image_barrier(
		cmd,
		engine.swapchain.images[engine.current_image_index],
		.Undefined,
		.Transfer_Dst,
		{.COLOR},
	)
	backend.copy_image_to_image(
		cmd,
		engine.swapchain.render_targets.draw.image,
		engine.swapchain.images[engine.current_image_index],
		engine.swapchain.extent,
		engine.swapchain.extent,
	)
	backend.image_barrier(cmd, engine.swapchain.images[engine.current_image_index], .Transfer_Dst, .Present, {.COLOR})

	backend.cmd_end_recording(cmd)
}

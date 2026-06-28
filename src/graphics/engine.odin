package graphics

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:time"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

initialize_vulkan :: proc(app: ^App) -> (ok: bool) {
	engine := &app.engine

	engine.clock.start_time = time.now()
	engine.clock.last_frame_time = engine.clock.start_time
	engine.camera = camera_create({2, 2, 4}, yaw = -90, pitch = -15)
	engine.ambient_light = AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.03,
	}

	create_vulkan_instance(&engine.vk_ctx)
	engine.vk_ctx.surface = create_vulkan_surface(app) or_return
	engine.vk_ctx.physical_device = find_physical_device(&engine.vk_ctx) or_return
	engine.vk_ctx.msaa_samples = get_max_usable_sample_count(&engine.vk_ctx)
	find_graphics_queue(&engine.vk_ctx) or_return
	create_logical_device(&engine.vk_ctx) or_return
	initialize_vma(&engine.vk_ctx)
	create_upload_pool(&engine.vk_ctx)

	create_swapchain(engine, app.width, app.height)
	create_color_resources(engine)
	create_depth_resources(engine)
	create_draw_image(engine)

	create_shader_system(engine) or_return
	shadow_map_handle := load_shader(engine, "shadow_map", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	ui_handle := load_shader(engine, "ui", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	mesh_handle := load_shader(engine, "mesh", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	particle_handle := load_shader(engine, "particle", {VERTEX_ENTRY, FRAGMENT_MAIN, COMPUTE_MAIN}) or_return
	skybox_handle := load_shader(engine, "skybox", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	debug_shadow_map_handle := load_shader(engine, "debug_shadow_map", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return

	create_sync_resources(engine)
	create_command_buffers(engine)
	create_scene_data_buffer(engine)

	create_texture_system(engine, {max_textures_count = MAX_TEXTURES})
	create_material_system(engine, {max_material_count = MAX_MATERIALS})
	create_model_system(engine)
	create_particle_buffer(engine)

	engine.skybox_descriptor = create_descriptor_set(
		engine,
		{{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}}},
	)

	engine.shadow_map_descriptor = create_descriptor_set(
		engine,
		{{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}}},
		count = MAX_FRAMES_IN_FLIGHT,
	)
	SHADOW_MAP_SIZE :: 2048
	engine.shadow_map_image = create_image(
		&engine.vk_ctx,
		{SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, 1},
		.D32_SFLOAT,
		{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
		array_layers = MAX_SHADOW_LIGHTS * 6,
		image_flags = {.CUBE_COMPATIBLE},
	)
	engine.shadow_map_image.image_view = create_image_view(
		&engine.vk_ctx,
		engine.shadow_map_image.image,
		.D32_SFLOAT,
		{.DEPTH},
		view_type    = .CUBE_ARRAY,
		array_layers = MAX_SHADOW_LIGHTS * 6,
	)

	for i in 0 ..< MAX_SHADOW_LIGHTS * 6 {
		engine.shadow_map_face_views[i] = create_image_view(
			&engine.vk_ctx,
			engine.shadow_map_image.image,
			.D32_SFLOAT,
			{.DEPTH},
			base_array_layer = u32(i),
			array_layers = 1,
		)
	}

	// shadow map sampler
	sampler_info := vk.SamplerCreateInfo {
		sType         = .SAMPLER_CREATE_INFO,
		magFilter     = .LINEAR,
		minFilter     = .LINEAR,
		mipmapMode    = .LINEAR,
		addressModeU  = .CLAMP_TO_EDGE,
		addressModeV  = .CLAMP_TO_EDGE,
		addressModeW  = .CLAMP_TO_EDGE,
		mipLodBias    = 0.0,
		maxAnisotropy = 1.0,
		minLod        = 0,
		maxLod        = 1.0,
		borderColor   = .FLOAT_OPAQUE_WHITE,
	}
	vk_check(vk.CreateSampler(engine.vk_ctx.device, &sampler_info, nil, &engine.shadow_map_sampler))
	shadow_map_image_info := vk.DescriptorImageInfo {
		sampler     = engine.shadow_map_sampler,
		imageView   = engine.shadow_map_image.image_view,
		imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
	}
	write_descriptor_image(&engine.vk_ctx, &engine.shadow_map_descriptor, 0, &shadow_map_image_info)
	write_descriptor_image(&engine.vk_ctx, &engine.texture_system.descriptor, 1, &shadow_map_image_info)

	register_pipeline(
		engine,
		"shadow_map",
		make_pipeline_descriptor(
			shader = shadow_map_handle,
			cull_mode = nil,
			depth_compare_op = .LESS_OR_EQUAL,
			depth_bias_enable = false,
			push_constant_size = size_of(ShadowPushConstants),
			push_constant_stages = {.VERTEX, .FRAGMENT},
			color_formats = nil,
		),
	)

	register_pipeline(
		engine,
		"ui",
		make_pipeline_descriptor(
			shader = ui_handle,
			cull_mode = {},
			depth_test = false,
			depth_write = false,
			blend = .Alpha,
		),
	)

	register_pipeline(
		engine,
		"mesh",
		make_pipeline_descriptor(
			shader = mesh_handle,
			blend = .Alpha,
			descriptor_layouts = {engine.texture_system.descriptor.layout},
			sample_count = engine.vk_ctx.msaa_samples,
		),
	)

	register_pipeline(
		engine,
		"particle_draw",
		make_pipeline_descriptor(
			shader = particle_handle,
			topology = .POINT_LIST,
			cull_mode = {},
			depth_test = false,
			depth_write = false,
			blend = .Alpha,
			push_constant_size = size_of(ParticlePushConstants),
			sample_count = engine.vk_ctx.msaa_samples,
		),
	)

	register_pipeline(
		engine,
		"particle",
		make_pipeline_descriptor(
			shader = particle_handle,
			type = .COMPUTE,
			push_constant_size = size_of(ParticlePushConstants),
			push_constant_stages = {.COMPUTE},
		),
	)

	register_pipeline(
		engine,
		"skybox",
		make_pipeline_descriptor(
			shader = skybox_handle,
			cull_mode = {},
			depth_write = false,
			depth_compare_op = .LESS_OR_EQUAL,
			push_constant_size = size_of(SkyboxPushConstants),
			descriptor_layouts = {engine.skybox_descriptor.layout},
			sample_count = engine.vk_ctx.msaa_samples,
		),
	)

	register_pipeline(
		engine,
		"debug_shadow_map",
		make_pipeline_descriptor(
			shader = debug_shadow_map_handle,
			cull_mode = {},
			depth_test = false,
			depth_write = false,
			push_constant_size = 2 * size_of(f32) + 2 * size_of(u32),
			push_constant_stages = {.FRAGMENT},
			descriptor_layouts = {engine.shadow_map_descriptor.layout},
			depth_format = .UNDEFINED,
		),
	)

	return true
}

engine_shutdown :: proc(self: ^Engine) {
	vk.DeviceWaitIdle(self.vk_ctx.device)

	destroy_texture_system(self)
	destroy_model_system(self)
	destroy_material_system(self)

	destroy_descriptor_set(self, &self.skybox_descriptor)
	destroy_descriptor_set(self, &self.shadow_map_descriptor)
	for view in self.shadow_map_face_views[:MAX_SHADOW_LIGHTS * 6] {
		vk.DestroyImageView(self.vk_ctx.device, view, nil)
	}
	destroy_image(&self.vk_ctx, self.shadow_map_image)
	vk.DestroySampler(self.vk_ctx.device, self.shadow_map_sampler, nil)

	destroy_pipeline_registry(self.vk_ctx.device, &self.pipeline_registry)

	destroy_shader_system(self)

	vk.DestroySemaphore(self.vk_ctx.device, self.timeline_semaphore, nil)
	for &res in self.frame_resources {
		destroy_buffer(&self.vk_ctx, res.scene_data_buffer)
		destroy_buffer(&self.vk_ctx, res.particle_buffer)
		vk.DestroySemaphore(self.vk_ctx.device, res.image_acquired_semaphore, nil)
		vk.DestroySemaphore(self.vk_ctx.device, res.render_complete_semaphore, nil)
		vk.DestroyCommandPool(self.vk_ctx.device, res.command_pool, nil)
	}
	cleanup_swapchain(self)

	destroy_vulkan_context(&self.vk_ctx)
}

destroy_vulkan_context :: proc(ctx: ^VulkanContext) {
	vk.DestroyCommandPool(ctx.device, ctx.upload_pool, nil)
	vma.destroy_allocator(ctx.vma_allocator)
	vk.DestroyDevice(ctx.device, nil)
	vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
	vk.DestroyInstance(ctx.instance, nil)
}

engine_render :: proc(app: ^App) {
	// recreate swapchain
	if app.engine.swapchain.require_recreate {
		vk.DeviceWaitIdle(app.engine.vk_ctx.device)
		cleanup_swapchain(&app.engine)
		create_swapchain(&app.engine, app.width, app.height)
		create_color_resources(&app.engine)
		create_depth_resources(&app.engine)
		create_draw_image(&app.engine)
		app.engine.swapchain.require_recreate = false
	}

	// wait until next frame can be drawn on
	if app.engine.next_signal_value >= MAX_FRAMES_IN_FLIGHT {
		wait_value := app.engine.next_signal_value - MAX_FRAMES_IN_FLIGHT + 1
		wait_info := vk.SemaphoreWaitInfo {
			sType          = .SEMAPHORE_WAIT_INFO,
			semaphoreCount = 1,
			pSemaphores    = &app.engine.timeline_semaphore,
			pValues        = &wait_value,
		}
		vk_check(vk.WaitSemaphores(app.engine.vk_ctx.device, &wait_info, max(u64)))
	}

	current_frame_res := &app.engine.frame_resources[current_frame_res_index(&app.engine)]

	// get the next swapchain image we can write too
	//
	// NOTE: purely chance, but your frame resources and swapchain count can be different
	// in our case, it was chance they are both two.
	acquire_result := vk.AcquireNextImageKHR(
		app.engine.vk_ctx.device,
		app.engine.swapchain.handle,
		max(u64),
		current_frame_res.image_acquired_semaphore,
		0,
		&app.engine.current_image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		app.engine.swapchain.require_recreate = true
		return
	} else if acquire_result == .SUBOPTIMAL_KHR {
		app.engine.swapchain.require_recreate = true
	}

	app.engine.next_signal_value += 1
	signal_value := app.engine.next_signal_value

	update_scene_data_buffer(&app.engine)
	check_shader_hotreload(&app.engine)

	record_command_buffer(&app.engine)

	cmd := current_frame_res.command_buffer

	// set the semaphore that tells the GPU only wait for the image
	// when you reach the stage for COLOR_ATTACHMENT_OUTPUT
	// COLOR_ATTACHMENT_OUTPUT is the transition image layout above
	image_acquired_wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = current_frame_res.image_acquired_semaphore,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}

	semaphore_signals := [2]vk.SemaphoreSubmitInfo {
		// signal the present engine that rendering is done and the image is ready to display
		{
			sType = .SEMAPHORE_SUBMIT_INFO,
			semaphore = current_frame_res.render_complete_semaphore,
			stageMask = {.ALL_GRAPHICS},
		},
		// signal the CPU frame pacing check so it knows this frame slot is free to reuse
		{
			sType = .SEMAPHORE_SUBMIT_INFO,
			semaphore = app.engine.timeline_semaphore,
			value = signal_value,
			stageMask = {.ALL_COMMANDS},
		},
	}

	cmd_submit_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}

	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &image_acquired_wait_info,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_submit_info,
		signalSemaphoreInfoCount = len(semaphore_signals),
		pSignalSemaphoreInfos    = &semaphore_signals[0],
	}

	// this point, everything is submitted to GPU
	vk_check(vk.QueueSubmit2(app.engine.vk_ctx.graphics_queue, 1, &submit_info, 0))

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &current_frame_res.render_complete_semaphore,
		swapchainCount     = 1,
		pSwapchains        = &app.engine.swapchain.handle,
		pImageIndices      = &app.engine.current_image_index,
	}

	present_result := vk.QueuePresentKHR(app.engine.vk_ctx.graphics_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR {
		app.engine.swapchain.require_recreate = true
	} else if present_result == .SUBOPTIMAL_KHR {
		app.engine.swapchain.require_recreate = true
	} else if present_result != .SUCCESS {
		log.errorf("QueuePresentKHR failed")
	}

	app.engine.frame_index += 1
}

current_frame_res_index :: proc(engine: ^Engine) -> u64 {
	return engine.frame_index % MAX_FRAMES_IN_FLIGHT
}

dispatch_particles :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, "particle")

	frame_res_index := current_frame_res_index(engine)
	last_frame := (frame_res_index + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT
	compute_pc := ParticlePushConstants {
		particles_in  = engine.frame_resources[last_frame].particle_buffer.ptr,
		particles_out = engine.frame_resources[frame_res_index].particle_buffer.ptr,
		delta_time    = engine.clock.delta_time,
	}
	vk.CmdBindPipeline(cmd, .COMPUTE, pipeline.pipeline)
	vk.CmdPushConstants(cmd, pipeline.layout, {.COMPUTE}, 0, size_of(ParticlePushConstants), &compute_pc)
	vk.CmdDispatch(cmd, PARTICLE_COUNT / 256, 1, 1)

	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.VERTEX_SHADER},
		dstAccessMask = {.SHADER_READ},
	}
	dep_info := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)
}

draw_particles :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, "particle_draw")

	frame_res_index := current_frame_res_index(engine)
	particle_pc := ParticlePushConstants {
		scene_data    = engine.frame_resources[frame_res_index].scene_data_buffer.ptr,
		particles_out = engine.frame_resources[frame_res_index].particle_buffer.ptr,
	}
	vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline.pipeline)
	vk.CmdPushConstants(cmd, pipeline.layout, {.VERTEX, .FRAGMENT}, 0, size_of(ParticlePushConstants), &particle_pc)
	vk.CmdDraw(cmd, PARTICLE_COUNT, 1, 0, 0)
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

draw_shadow_casters :: proc(engine: ^Engine, cmd: vk.CommandBuffer, light_i: u32, face_i: u32) {
	shadow_map_pipeline := get_pipeline(&engine.pipeline_registry, "shadow_map")

	vk.CmdBindPipeline(cmd, .GRAPHICS, shadow_map_pipeline.pipeline)
	vk.CmdSetDepthBias(cmd, 0, 0, 0)

	transforms := (^GpuTransform)(engine.model_system.transforms_buffer.alloc_info.mapped_data)
	for &slot, slot_i in engine.model_system.instances.slots {
		if !slot.alive do continue
		instance := &slot.value

		mem.ptr_offset(transforms, slot_i)^ = GpuTransform {
			model         = transform_matrix(instance.transform),
			normal_matrix = {},
		}

		model_ptr := &pool_get(&engine.model_system.models, instance.model)^

		for &mesh in model_ptr.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend do continue

			pc := ShadowPushConstants {
				scene_data       = engine.frame_resources[current_frame_res_index(engine)].scene_data_buffer.ptr,
				vertex_buffer    = mesh.vertex_address,
				transform_buffer = engine.model_system.transforms_buffer.ptr,
				instance_index   = u32(slot_i),
				face_index       = face_i,
				light_index      = light_i,
			}
			vk.CmdPushConstants(cmd, shadow_map_pipeline.layout, {.VERTEX, .FRAGMENT}, 0, size_of(ShadowPushConstants), &pc)
			vk.CmdBindIndexBuffer(cmd, mesh.index_buffer, 0, .UINT32)
			vk.CmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0)
		}
	}
}

draw_meshes :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	mesh_pipeline := get_pipeline(&engine.pipeline_registry, "mesh")

	vk.CmdBindPipeline(cmd, .GRAPHICS, mesh_pipeline.pipeline)
	vk.CmdBindDescriptorSets(
		cmd,
		.GRAPHICS,
		mesh_pipeline.layout,
		0,
		1,
		&engine.texture_system.descriptor.sets[current_frame_res_index(engine)],
		0,
		nil,
	)

	transforms := (^GpuTransform)(engine.model_system.transforms_buffer.alloc_info.mapped_data)
	for &slot, i in engine.model_system.instances.slots {
		if !slot.alive do continue
		instance := &slot.value
		model := transform_matrix(instance.transform)
		normal := linalg.transpose(linalg.inverse(model))

		mem.ptr_offset(transforms, i)^ = GpuTransform {
			model         = model,
			normal_matrix = normal,
		}
	}

	draw_instance :: proc(engine: ^Engine, cmd: vk.CommandBuffer, i: int) {
		instance := &engine.model_system.instances.slots[i].value
		model := &pool_get(&engine.model_system.models, instance.model)^
		for &mesh in model.meshes {
			pc := PushConstants {
				scene_data       = engine.frame_resources[current_frame_res_index(engine)].scene_data_buffer.ptr,
				vertex_buffer    = mesh.vertex_address,
				material_buffer  = engine.material_system.buffer.ptr,
				transform_buffer = engine.model_system.transforms_buffer.ptr,
				material_index   = u32(mesh.material.index),
				instance_index   = u32(i),
			}
			vk.CmdPushConstants(
				cmd,
				get_pipeline(&engine.pipeline_registry, "mesh").layout,
				{.VERTEX, .FRAGMENT},
				0,
				size_of(PushConstants),
				&pc,
			)
			vk.CmdBindIndexBuffer(cmd, mesh.index_buffer, 0, .UINT32)
			vk.CmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0)
		}
	}

	// opaque + mask
	for &slot, i in engine.model_system.instances.slots {
		if !slot.alive do continue
		instance := &slot.value
		model := &pool_get(&engine.model_system.models, instance.model)^
		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend do continue
			draw_instance(engine, cmd, i)
			break
		}
	}

	// transparent — collect and sort back-to-front
	TransparentEntry :: struct {
		index: int,
		dist:  f32,
	}
	transparent := make([dynamic]TransparentEntry, context.temp_allocator)
	for &slot, i in engine.model_system.instances.slots {
		if !slot.alive do continue
		instance := &slot.value
		model := &pool_get(&engine.model_system.models, instance.model)^
		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode != .Blend do continue
			pos := instance.transform.translation
			cam := engine.camera.position
			dist := linalg.length(pos - cam)
			append(&transparent, TransparentEntry{index = i, dist = dist})
			break
		}
	}

	slice.sort_by(transparent[:], proc(a, b: TransparentEntry) -> bool {return a.dist > b.dist})
	for entry in transparent {
		draw_instance(engine, cmd, entry.index)
	}
}

set_skybox_texture :: proc(engine: ^Engine, handle: TextureHandle) {
	write_descriptor_texture(engine, &engine.skybox_descriptor, 0, handle)
}

draw_skybox :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, "skybox")
	vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline.pipeline)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, pipeline.layout, 0, 1, &engine.skybox_descriptor.sets[0], 0, nil)
	frame_idx := current_frame_res_index(engine)
	pc := SkyboxPushConstants {
		scene_data = engine.frame_resources[frame_idx].scene_data_buffer.ptr,
	}
	vk.CmdPushConstants(cmd, pipeline.layout, {.VERTEX, .FRAGMENT}, 0, size_of(SkyboxPushConstants), &pc)
	vk.CmdDraw(cmd, 3, 1, 0, 0)
}

draw_debug_shadow_map :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	DEBUG_SIZE :: 128
	pipeline := get_pipeline(&engine.pipeline_registry, "debug_shadow_map")
	begin_render_pass(engine, cmd, PassConfig{color_target = &engine.swapchain.draw_image, load_op = .LOAD})
	vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline.pipeline)
	vk.CmdBindDescriptorSets(
		cmd,
		.GRAPHICS,
		pipeline.layout,
		0,
		1,
		&engine.shadow_map_descriptor.sets[current_frame_res_index(engine)],
		0,
		nil,
	)
	scene_data := (^SceneData)(engine.frame_resources[current_frame_res_index(engine)].scene_data_buffer.alloc_info.mapped_data)

	DebugPC :: struct {near, far: f32, face, light: u32}
	for face in 0..<6 {
		viewport := vk.Viewport{
			x        = f32(face) * DEBUG_SIZE,
			y        = 0,
			width    = DEBUG_SIZE,
			height   = DEBUG_SIZE,
			minDepth = 0,
			maxDepth = 1,
		}
		scissor := vk.Rect2D{
			offset = {i32(face) * DEBUG_SIZE, 0},
			extent = {DEBUG_SIZE, DEBUG_SIZE},
		}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		debug_pc := DebugPC{scene_data.shadow_near, scene_data.shadow_far, u32(face), 0}
		vk.CmdPushConstants(cmd, pipeline.layout, {.FRAGMENT}, 0, size_of(DebugPC), &debug_pc)
		vk.CmdDraw(cmd, 3, 1, 0, 0)
	}
	end_render_pass(cmd)
}

draw_ui :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, "ui")
	vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline.pipeline)
	vk.CmdDraw(cmd, 6, 1, 0, 0)
}

draw_scene :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	// dispatch_particles(engine, cmd)

	shadow_light_count := min(int(engine.point_light_count), MAX_SHADOW_LIGHTS)

	// Always transition all MAX_SHADOW_LIGHTS*6 layers so unused layers are in the
	// expected layout when the mesh pass samples the descriptor.
	transition_image_layout(
		cmd,
		engine.shadow_map_image.image,
		.UNDEFINED,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.EARLY_FRAGMENT_TESTS},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{.DEPTH},
		layer_count = MAX_SHADOW_LIGHTS * 6,
	)
	for light_i in 0 ..< shadow_light_count {
		for face_i in 0 ..< 6 {
			view_i := light_i * 6 + face_i
			begin_render_pass(
				engine,
				cmd,
				PassConfig{
					depth_target          = &engine.shadow_map_image,
					depth_view            = engine.shadow_map_face_views[view_i],
					load_op               = .CLEAR,
					store_depth           = true,
					skip_depth_transition = true,
				},
			)
			draw_shadow_casters(engine, cmd, u32(light_i), u32(face_i))
			end_render_pass(cmd)
		}
	}

	transition_image_layout(
		cmd,
		engine.shadow_map_image.image,
		.DEPTH_ATTACHMENT_OPTIMAL,
		.DEPTH_STENCIL_READ_ONLY_OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.SHADER_READ},
		{.LATE_FRAGMENT_TESTS},
		{.FRAGMENT_SHADER},
		{.DEPTH},
		layer_count = MAX_SHADOW_LIGHTS * 6,
	)

	begin_render_pass(
		engine,
		cmd,
		PassConfig {
			color_target = &engine.swapchain.color_image,
			resolve_target = &engine.swapchain.draw_image,
			depth_target = &engine.swapchain.depth_image,
			clear_color = {0.1, 0.1, 0.1, 1},
			load_op = .CLEAR,
		},
	)
	draw_meshes(engine, cmd)
	draw_skybox(engine, cmd)
	// draw_particles(engine, cmd)
	end_render_pass(cmd)

	draw_debug_shadow_map(engine, cmd)

	// begin_render_pass(engine, cmd, PassConfig{color_target = &engine.swapchain.draw_image, load_op = .LOAD})
	// draw_ui(engine, cmd)
	// end_render_pass(cmd)
}

record_command_buffer :: proc(engine: ^Engine) {
	current_frame_res := &engine.frame_resources[current_frame_res_index(engine)]

	vk.ResetCommandPool(engine.vk_ctx.device, current_frame_res.command_pool, {})

	cmd := current_frame_res.command_buffer

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	draw_scene(engine, cmd)

	transition_image_layout(
		cmd,
		engine.swapchain.draw_image.image,
		.COLOR_ATTACHMENT_OPTIMAL,
		.TRANSFER_SRC_OPTIMAL,
		{.COLOR_ATTACHMENT_WRITE},
		{.TRANSFER_READ},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER},
		{.COLOR},
	)

	transition_image_layout(
		cmd,
		engine.swapchain.images[engine.current_image_index],
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{},
		{.TRANSFER_WRITE},
		{},
		{.TRANSFER},
		{.COLOR},
	)

	copy_image_to_image(
		cmd,
		engine.swapchain.draw_image.image,
		engine.swapchain.images[engine.current_image_index],
		engine.swapchain.extent,
		engine.swapchain.extent,
	)

	transition_image_layout(
		cmd,
		engine.swapchain.images[engine.current_image_index],
		.TRANSFER_DST_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.TRANSFER_WRITE},
		{},
		{.TRANSFER},
		{},
		{.COLOR},
	)

	vk_check(vk.EndCommandBuffer(cmd))
}

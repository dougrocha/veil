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
	engine.scene.camera = camera_create({2, 2, 4}, yaw = -90, pitch = -15)
	engine.scene.ambient_light = AmbientLight {
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

	swapchain_create(engine, app.width, app.height)
	engine.swapchain.render_targets = render_targets_create(
		&engine.vk_ctx,
		engine.swapchain.extent,
		engine.vk_ctx.msaa_samples,
	)

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

	texture_system_create(engine, {max_textures_count = MAX_TEXTURES})
	create_material_system(engine, {max_material_count = MAX_MATERIALS})
	create_model_system(engine)
	create_particle_buffer(engine)
	create_transforms_buffer(engine)

	engine.global_descriptor = create_descriptor_set(
		engine,
		{
			{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
			{binding = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		},
		count = MAX_FRAMES_IN_FLIGHT,
	)
	engine.shadow_atlas = shadow_atlas_create(&engine.vk_ctx, SHADOW_MAP_SIZE)
	shadow_map_image_info := vk.DescriptorImageInfo {
		sampler     = engine.shadow_atlas.sampler,
		imageView   = engine.shadow_atlas.cube_array_view,
		imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
	}
	write_descriptor_image(&engine.vk_ctx, &engine.global_descriptor, 0, &shadow_map_image_info)

	// Shadow
	{
		config := new(GraphicsPipelineConfig)
		pipeline_default_config(config)
		config.rasterization_info.cullMode = {}
		config.depth_stencil_info.depthCompareOp = .LESS_OR_EQUAL
		config.rendering_info = {
			sType                 = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount  = 0,
			depthAttachmentFormat = DEPTH_FORMAT,
		}
		config.push_constant_range = {
			stageFlags = {.VERTEX, .FRAGMENT},
			size       = size_of(ShadowPushConstants),
		}
		shader_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = get_shader(engine, shadow_map_handle),
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = get_shader(engine, shadow_map_handle),
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_register(engine, .Shadow, shadow_map_handle, config, shader_stages)
	}

	// UI
	{
		config := new(GraphicsPipelineConfig)
		pipeline_default_config(config)
		config.rasterization_info.cullMode = {}
		pipeline_config_disable_depth(config)
		pipeline_config_set_blend(config, .Alpha)
		config.push_constant_range = {
			stageFlags = {.VERTEX, .FRAGMENT},
			size       = size_of(PushConstants),
		}
		shader_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = get_shader(engine, ui_handle),
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = get_shader(engine, ui_handle),
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_register(engine, .UI, ui_handle, config, shader_stages)
	}

	// Mesh
	{
		config := new(GraphicsPipelineConfig)
		pipeline_default_config(config)
		config.multi_sample_info.rasterizationSamples = engine.vk_ctx.msaa_samples
		pipeline_config_set_blend(config, .Alpha)
		config.descriptor_layouts[0] = engine.texture_system.descriptor.layout
		config.descriptor_layouts[1] = engine.global_descriptor.layout
		config.descriptor_layout_count = 2
		config.push_constant_range = {
			stageFlags = {.VERTEX, .FRAGMENT},
			size       = size_of(PushConstants),
		}
		shader_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = get_shader(engine, mesh_handle),
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = get_shader(engine, mesh_handle),
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_register(engine, .Mesh, mesh_handle, config, shader_stages)
	}

	// Particle_Draw
	{
		config := new(GraphicsPipelineConfig)
		pipeline_default_config(config)
		config.input_assembly_info.topology = .POINT_LIST
		config.rasterization_info.cullMode = {}
		config.multi_sample_info.rasterizationSamples = engine.vk_ctx.msaa_samples
		pipeline_config_disable_depth(config)
		pipeline_config_set_blend(config, .Alpha)
		config.push_constant_range = {
			stageFlags = {.VERTEX, .FRAGMENT},
			size       = size_of(ParticlePushConstants),
		}
		shader_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = get_shader(engine, particle_handle),
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = get_shader(engine, particle_handle),
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_register(engine, .Particle_Draw, particle_handle, config, shader_stages)
	}

	// Particle_Compute
	{
		config := new(ComputePipelineConfig)
		config.push_constant_range = {
			stageFlags = {.COMPUTE},
			size       = size_of(ParticlePushConstants),
		}
		shader_stage := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.COMPUTE},
			module = get_shader(engine, particle_handle),
			pName  = cstring(COMPUTE_MAIN),
		}
		pipeline_register_compute(engine, .Particle_Compute, particle_handle, config, shader_stage)
	}

	// Skybox
	{
		config := new(GraphicsPipelineConfig)
		pipeline_default_config(config)
		config.rasterization_info.cullMode = {}
		config.depth_stencil_info.depthWriteEnable = false
		config.depth_stencil_info.depthCompareOp = .LESS_OR_EQUAL
		config.multi_sample_info.rasterizationSamples = engine.vk_ctx.msaa_samples
		config.descriptor_layouts[0] = engine.global_descriptor.layout
		config.descriptor_layout_count = 1
		config.push_constant_range = {
			stageFlags = {.VERTEX, .FRAGMENT},
			size       = size_of(SkyboxPushConstants),
		}
		shader_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = get_shader(engine, skybox_handle),
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = get_shader(engine, skybox_handle),
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_register(engine, .Skybox, skybox_handle, config, shader_stages)
	}

	// Debug_Shadow
	{
		config := new(GraphicsPipelineConfig)
		pipeline_default_config(config)
		config.rasterization_info.cullMode = {}
		pipeline_config_disable_depth(config)
		config.rendering_info.depthAttachmentFormat = .UNDEFINED
		config.descriptor_layouts[0] = engine.global_descriptor.layout
		config.descriptor_layout_count = 1
		config.push_constant_range = {
			stageFlags = {.FRAGMENT},
			size       = 2 * size_of(f32) + 2 * size_of(u32),
		}
		shader_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = get_shader(engine, debug_shadow_map_handle),
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = get_shader(engine, debug_shadow_map_handle),
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_register(engine, .Debug_Shadow, debug_shadow_map_handle, config, shader_stages)
	}

	return true
}

engine_shutdown :: proc(self: ^Engine) {
	vk.DeviceWaitIdle(self.vk_ctx.device)

	texture_system_destroy(self)
	destroy_model_system(self)
	destroy_material_system(self)

	destroy_descriptor_set(self, &self.global_descriptor)
	shadow_atlas_destroy(&self.vk_ctx, &self.shadow_atlas)

	destroy_pipeline_registry(self.vk_ctx.device, &self.pipeline_registry)

	destroy_shader_system(self)

	vk.DestroySemaphore(self.vk_ctx.device, self.timeline_semaphore, nil)
	for &res in self.frame_resources {
		buffer_destroy(&self.vk_ctx, res.scene_data_buffer)
		buffer_destroy(&self.vk_ctx, res.particle_buffer)
		buffer_destroy(&self.vk_ctx, res.transforms_buffer)
		vk.DestroySemaphore(self.vk_ctx.device, res.image_acquired_semaphore, nil)
		vk.DestroySemaphore(self.vk_ctx.device, res.render_complete_semaphore, nil)
		vk.DestroyCommandPool(self.vk_ctx.device, res.command_pool, nil)
	}
	swapchain_destroy(&self.vk_ctx, &self.swapchain)

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
		swapchain_destroy(&app.engine.vk_ctx, &app.engine.swapchain)
		swapchain_create(&app.engine, app.width, app.height)
		app.engine.swapchain.render_targets = render_targets_create(
			&app.engine.vk_ctx,
			app.engine.swapchain.extent,
			app.engine.vk_ctx.msaa_samples,
		)
		app.engine.swapchain.require_recreate = false
	}

	// wait until next frame can be drawn on
	next_signal_value := app.engine.frame_index + 1
	if next_signal_value >= MAX_FRAMES_IN_FLIGHT {
		wait_value := next_signal_value - MAX_FRAMES_IN_FLIGHT + 1
		wait_info := vk.SemaphoreWaitInfo {
			sType          = .SEMAPHORE_WAIT_INFO,
			semaphoreCount = 1,
			pSemaphores    = &app.engine.timeline_semaphore,
			pValues        = &wait_value,
		}
		vk_check(vk.WaitSemaphores(app.engine.vk_ctx.device, &wait_info, max(u64)))
	}

	current_frame_res := current_frame(&app.engine)

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

	signal_value := next_signal_value

	scene_data_buffer_update(&app.engine)
	update_transforms_buffer(&app.engine)
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

current_frame :: #force_inline proc(engine: ^Engine) -> ^FrameResources {
	return &engine.frame_resources[current_frame_res_index(engine)]
}

dispatch_particles :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Particle_Compute)

	frame_res_index := current_frame_res_index(engine)
	last_frame := (frame_res_index + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT
	compute_pc := ParticlePushConstants {
		particles_in  = engine.frame_resources[last_frame].particle_buffer.ptr,
		particles_out = engine.frame_resources[frame_res_index].particle_buffer.ptr,
		delta_time    = engine.clock.delta_time,
	}
	pipeline_bind(cmd, pipeline, .COMPUTE)
	pipeline_push(cmd, pipeline, {.COMPUTE}, &compute_pc)
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
	pipeline := get_pipeline(&engine.pipeline_registry, .Particle_Draw)

	frame_res_index := current_frame_res_index(engine)
	particle_pc := ParticlePushConstants {
		scene_data    = engine.frame_resources[frame_res_index].scene_data_buffer.ptr,
		particles_out = engine.frame_resources[frame_res_index].particle_buffer.ptr,
	}
	pipeline_bind(cmd, pipeline)
	pipeline_push(cmd, pipeline, {.VERTEX, .FRAGMENT}, &particle_pc)
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

update_transforms_buffer :: proc(engine: ^Engine) {
	transforms := (^GpuTransform)(current_frame(engine).transforms_buffer.alloc_info.mapped_data)
	for &instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, u32(i)) do continue
		model := transform_matrix(instance.transform)
		normal := linalg.transpose(linalg.inverse(model))

		mem.ptr_offset(transforms, i)^ = GpuTransform {
			model         = model,
			normal_matrix = normal,
		}
	}
}

draw_shadow_casters :: proc(engine: ^Engine, cmd: vk.CommandBuffer, light_i: u32, face_i: u32) {
	shadow_map_pipeline := get_pipeline(&engine.pipeline_registry, .Shadow)

	pipeline_bind(cmd, shadow_map_pipeline)
	vk.CmdSetDepthBias(cmd, 0, 0, 0)

	frame := current_frame(engine)

	scene_data := (^SceneData)(current_frame(engine).scene_data_buffer.alloc_info.mapped_data)
	frustum := frustum_from_view_proj(scene_data.light_view_proj[light_i][face_i])

	for &instance, slot_i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, u32(slot_i)) do continue

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
				instance_index   = u32(slot_i),
				face_index       = face_i,
				light_index      = light_i,
			}
			pipeline_push(cmd, shadow_map_pipeline, {.VERTEX, .FRAGMENT}, &pc)
			vk.CmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, .UINT32)
			vk.CmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0)
		}
	}
}

draw_meshes :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	engine.drawn_instance_count = 0

	mesh_pipeline := get_pipeline(&engine.pipeline_registry, .Mesh)

	frame_idx := current_frame_res_index(engine)
	sets := [2]vk.DescriptorSet {
		engine.texture_system.descriptor.sets[frame_idx],
		engine.global_descriptor.sets[frame_idx],
	}
	pipeline_bind(cmd, mesh_pipeline, .GRAPHICS, sets[:])

	frustum := frustum_create_from_camera(
		&engine.scene.camera,
		f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height),
		linalg.to_radians(engine.scene.camera.zoom),
		0.1,
		5000.0,
	)

	draw_instance :: proc(engine: ^Engine, frustum: Frustum, cmd: vk.CommandBuffer, i: int, blend: bool) {
		instance := &engine.scene.instances.values[i]
		model := pool_get(&engine.model_system.models, instance.model)

		if !volume_is_on_frustum(frustum, model.bounds, instance.transform) {
			return
		}
		engine.drawn_instance_count += 1

		frame := current_frame(engine)
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
			pipeline_push(cmd, get_pipeline(&engine.pipeline_registry, .Mesh), {.VERTEX, .FRAGMENT}, &pc)
			vk.CmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, .UINT32)
			vk.CmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0)
		}
	}

	// opaque + mask
	for &instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, u32(i)) do continue
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
		if !pool_is_alive(&engine.scene.instances, u32(i)) do continue
		model := &pool_get(&engine.model_system.models, instance.model)^
		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode != .Blend do continue
			pos := instance.transform.translation
			cam := engine.scene.camera.position
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
	image_info := vk.DescriptorImageInfo {
		sampler     = t.sampler,
		imageView   = t.image_view,
		imageLayout = .READ_ONLY_OPTIMAL,
	}
	write_descriptor_image(&engine.vk_ctx, &engine.global_descriptor, 1, &image_info)
}

draw_skybox :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Skybox)
	skybox_frame_idx := current_frame_res_index(engine)
	pipeline_bind(cmd, pipeline, .GRAPHICS, {engine.global_descriptor.sets[skybox_frame_idx]})
	pc := SkyboxPushConstants {
		scene_data = current_frame(engine).scene_data_buffer.ptr,
	}
	pipeline_push(cmd, pipeline, {.VERTEX, .FRAGMENT}, &pc)
	vk.CmdDraw(cmd, 3, 1, 0, 0)
}

draw_debug_shadow_map :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	DEBUG_SIZE :: 128
	pipeline := get_pipeline(&engine.pipeline_registry, .Debug_Shadow)
	begin_render_pass(engine, cmd, PassConfig{color_target = &engine.swapchain.render_targets.draw, load_op = .LOAD})
	pipeline_bind(cmd, pipeline, .GRAPHICS, {engine.global_descriptor.sets[current_frame_res_index(engine)]})
	scene_data := (^SceneData)(current_frame(engine).scene_data_buffer.alloc_info.mapped_data)

	DebugPC :: struct {
		near, far:   f32,
		face, light: u32,
	}
	for face in 0 ..< 6 {
		viewport := vk.Viewport {
			x        = f32(face) * DEBUG_SIZE,
			y        = 0,
			width    = DEBUG_SIZE,
			height   = DEBUG_SIZE,
			minDepth = 0,
			maxDepth = 1,
		}
		scissor := vk.Rect2D {
			offset = {i32(face) * DEBUG_SIZE, 0},
			extent = {DEBUG_SIZE, DEBUG_SIZE},
		}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		debug_pc := DebugPC{scene_data.shadow_near, scene_data.shadow_far, u32(face), 0}
		pipeline_push(cmd, pipeline, {.FRAGMENT}, &debug_pc)
		vk.CmdDraw(cmd, 3, 1, 0, 0)
	}
	end_render_pass(cmd)
}

draw_ui :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .UI)
	pipeline_bind(cmd, pipeline)
	vk.CmdDraw(cmd, 6, 1, 0, 0)
}

draw_scene :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	// dispatch_particles(engine, cmd)

	shadow_light_count := min(int(engine.scene.point_light_count), MAX_SHADOW_LIGHTS)

	// Always transition all MAX_SHADOW_LIGHTS*6 layers so unused layers are in the
	// expected layout when the mesh pass samples the descriptor.
	transition_image_layout(
		cmd,
		engine.shadow_atlas.image,
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
				PassConfig {
					depth_target = &engine.shadow_atlas.gpu_image,
					depth_view = engine.shadow_atlas.face_views[view_i],
					load_op = .CLEAR,
					store_depth = true,
					skip_depth_transition = true,
				},
			)
			draw_shadow_casters(engine, cmd, u32(light_i), u32(face_i))
			end_render_pass(cmd)
		}
	}

	transition_image_layout(
		cmd,
		engine.shadow_atlas.image,
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
			color_target = &engine.swapchain.render_targets.color,
			resolve_target = &engine.swapchain.render_targets.draw,
			depth_target = &engine.swapchain.render_targets.depth,
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
	current_frame_res := current_frame(engine)

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
		engine.swapchain.render_targets.draw.image,
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
		engine.swapchain.render_targets.draw.image,
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

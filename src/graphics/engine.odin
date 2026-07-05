package graphics

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:time"

import "backend"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

// TEMP exports
VulkanContext :: backend.VulkanContext
Swapchain :: backend.Swapchain
GpuImage :: backend.GpuImage
DescriptorSet :: backend.DescriptorSet
vk_check :: backend.vk_check
GpuBuffer :: backend.GpuBuffer
GPUPtr :: backend.GPUPtr
GraphicsPipelineConfig :: backend.GraphicsPipelineConfig
ComputePipelineConfig :: backend.ComputePipelineConfig
PipelineConfig :: backend.PipelineConfig

TEXTURE_FORMAT :: vk.Format.R8G8B8A8_SRGB
TEXTURE_FORMAT_LINEAR :: vk.Format.R8G8B8A8_UNORM

SWAPCHAIN_FORMAT :: backend.SWAPCHAIN_FORMAT
DEPTH_FORMAT :: backend.DEPTH_FORMAT
DRAW_FORMAT :: backend.DRAW_FORMAT
MAX_FRAMES_IN_FLIGHT :: backend.MAX_FRAMES_IN_FLIGHT

initialize_vulkan :: proc(app: ^App) -> (ok: bool) {
	engine := &app.engine

	engine.clock.start_time = time.now()
	engine.clock.last_frame_time = engine.clock.start_time
	engine.scene.camera = camera_create({-9, 5, 1}, yaw = -6, pitch = -29)
	engine.scene.ambient_light = AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.03,
	}

	vk_ctx := &engine.vk_ctx
	backend.context_init(vk_ctx, app.window)
	backend.upload_pool_create(vk_ctx)

	engine.swapchain = backend.swapchain_create(vk_ctx, app.width, app.height)
	engine.swapchain.render_targets = backend.render_targets_create(
		vk_ctx,
		engine.swapchain.extent,
		engine.vk_ctx.msaa_samples,
	)

	create_shader_system(engine) or_return
	dir_shadow_map_handle := load_shader(engine, "dir_shadow_map", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	shadow_map_handle := load_shader(engine, "shadow_map", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	ui_handle := load_shader(engine, "ui", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	mesh_handle := load_shader(engine, "mesh", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	particle_handle := load_shader(engine, "particle", {VERTEX_ENTRY, FRAGMENT_MAIN, COMPUTE_MAIN}) or_return
	skybox_handle := load_shader(engine, "skybox", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	debug_shadow_map_handle := load_shader(engine, "debug_shadow_map", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return

	backend.frame_sync_create(vk_ctx)
	frame_data_create(engine)

	texture_system_create(engine, {max_textures_count = MAX_TEXTURES})
	material_system_create(engine, {max_material_count = MAX_MATERIALS})
	create_model_system(engine)

	log.infof("Here")

	engine.global_descriptor = backend.descriptor_set_create(
		vk_ctx,
		{
			{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
			{binding = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
			{binding = 2, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		},
		count = MAX_FRAMES_IN_FLIGHT,
	)
	engine.shadow_atlas = shadow_atlas_create(vk_ctx, SHADOW_MAP_SIZE)
	shadow_map_image_info := vk.DescriptorImageInfo {
		sampler     = engine.shadow_atlas.sampler,
		imageView   = engine.shadow_atlas.image_view,
		imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
	}
	backend.descriptor_write_image_info(vk_ctx, &engine.global_descriptor, 0, &shadow_map_image_info)
	engine.dir_shadow_atlas = dir_shadow_atlas_create(vk_ctx, SHADOW_MAP_SIZE)
	dir_shadow_map_image_info := vk.DescriptorImageInfo {
		sampler     = engine.dir_shadow_atlas.sampler,
		imageView   = engine.dir_shadow_atlas.image_view,
		imageLayout = .DEPTH_STENCIL_READ_ONLY_OPTIMAL,
	}
	backend.descriptor_write_image_info(vk_ctx, &engine.global_descriptor, 2, &dir_shadow_map_image_info)


	// Shadow
	{
		config := new(GraphicsPipelineConfig)
		backend.pipeline_default_config(config)
		config.rasterization_info.cullMode = {}
		config.rasterization_info.depthBiasEnable = true
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

		dir_config := new(GraphicsPipelineConfig)
		backend.pipeline_default_config(dir_config)
		dir_config.rasterization_info.cullMode = {}
		dir_config.rasterization_info.depthBiasEnable = true
		dir_config.depth_stencil_info.depthCompareOp = .LESS_OR_EQUAL
		dir_config.rendering_info = {
			sType                 = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount  = 0,
			depthAttachmentFormat = DEPTH_FORMAT,
		}
		dir_config.push_constant_range = {
			stageFlags = {.VERTEX, .FRAGMENT},
			size       = size_of(ShadowPushConstants),
		}
		dir_shader_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = get_shader(engine, dir_shadow_map_handle),
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = get_shader(engine, dir_shadow_map_handle),
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_register(engine, .Shadow_Directional, dir_shadow_map_handle, dir_config, dir_shader_stages)
	}

	// UI
	{
		config := new(GraphicsPipelineConfig)
		backend.pipeline_default_config(config)
		config.rasterization_info.cullMode = {}
		backend.pipeline_config_disable_depth(config)
		backend.pipeline_config_set_blend(config, .Alpha)
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
		backend.pipeline_default_config(config)
		config.multi_sample_info.rasterizationSamples = engine.vk_ctx.msaa_samples
		backend.pipeline_config_set_blend(config, .Alpha)
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
		backend.pipeline_default_config(config)
		config.input_assembly_info.topology = .POINT_LIST
		config.rasterization_info.cullMode = {}
		config.multi_sample_info.rasterizationSamples = engine.vk_ctx.msaa_samples
		backend.pipeline_config_disable_depth(config)
		backend.pipeline_config_set_blend(config, .Alpha)
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
		backend.pipeline_default_config(config)
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
		backend.pipeline_default_config(config)
		config.rasterization_info.cullMode = {}
		backend.pipeline_config_disable_depth(config)
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
	material_system_destroy(self)

	backend.descriptor_set_destroy(&self.vk_ctx, &self.global_descriptor)
	shadow_atlas_destroy(&self.vk_ctx, &self.shadow_atlas)
	dir_shadow_atlas_destroy(&self.vk_ctx, &self.dir_shadow_atlas)

	destroy_pipeline_registry(self.vk_ctx.device, &self.pipeline_registry)

	destroy_shader_system(self)

	for &res in self.frame_data {
		backend.buffer_destroy(&self.vk_ctx, res.scene_data_buffer)
		backend.buffer_destroy(&self.vk_ctx, res.particle_buffer)
		backend.buffer_destroy(&self.vk_ctx, res.transforms_buffer)
	}
	backend.frame_sync_destroy(&self.vk_ctx)
	backend.swapchain_destroy(&self.vk_ctx, &self.swapchain)

	backend.context_destroy(&self.vk_ctx)
}

engine_render :: proc(app: ^App) {
	// recreate swapchain
	if app.engine.swapchain.require_recreate {
		vk.DeviceWaitIdle(app.engine.vk_ctx.device)
		backend.swapchain_destroy(&app.engine.vk_ctx, &app.engine.swapchain)
		app.engine.swapchain = backend.swapchain_create(&app.engine.vk_ctx, app.width, app.height)
		app.engine.swapchain.render_targets = backend.render_targets_create(
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
			pSemaphores    = &app.engine.vk_ctx.timeline_semaphore,
			pValues        = &wait_value,
		}
		vk_check(vk.WaitSemaphores(app.engine.vk_ctx.device, &wait_info, max(u64)))
	}

	current_frame_sync := backend.current_frame_sync(&app.engine.vk_ctx, app.engine.frame_index)
	current_frame_data := current_frame_data(&app.engine)

	// get the next swapchain image we can write too
	//
	// NOTE: purely chance, but your frame resources and swapchain count can be different
	// in our case, it was chance they are both two.
	acquire_result := vk.AcquireNextImageKHR(
		app.engine.vk_ctx.device,
		app.engine.swapchain.handle,
		max(u64),
		current_frame_sync.image_acquired_semaphore,
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

	cmd := current_frame_sync.command_buffer

	// set the semaphore that tells the GPU only wait for the image
	// when you reach the stage for COLOR_ATTACHMENT_OUTPUT
	// COLOR_ATTACHMENT_OUTPUT is the transition image layout above
	image_acquired_wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = current_frame_sync.image_acquired_semaphore,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}

	semaphore_signals := [2]vk.SemaphoreSubmitInfo {
		// signal the present engine that rendering is done and the image is ready to display
		{
			sType = .SEMAPHORE_SUBMIT_INFO,
			semaphore = current_frame_sync.render_complete_semaphore,
			stageMask = {.ALL_GRAPHICS},
		},
		// signal the CPU frame pacing check so it knows this frame slot is free to reuse
		{
			sType = .SEMAPHORE_SUBMIT_INFO,
			semaphore = app.engine.vk_ctx.timeline_semaphore,
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
		pWaitSemaphores    = &current_frame_sync.render_complete_semaphore,
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

current_frame_data :: #force_inline proc(engine: ^Engine) -> ^FrameData {
	return &engine.frame_data[current_frame_res_index(engine)]
}

dispatch_particles :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Particle_Compute)

	frame_res_index := current_frame_res_index(engine)
	last_frame := (frame_res_index + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT
	compute_pc := ParticlePushConstants {
		particles_in  = engine.frame_data[last_frame].particle_buffer.ptr,
		particles_out = engine.frame_data[frame_res_index].particle_buffer.ptr,
		delta_time    = engine.clock.delta_time,
	}
	backend.pipeline_bind(cmd, pipeline, .COMPUTE)
	backend.pipeline_push(cmd, pipeline, {.COMPUTE}, &compute_pc)
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
		scene_data    = engine.frame_data[frame_res_index].scene_data_buffer.ptr,
		particles_out = engine.frame_data[frame_res_index].particle_buffer.ptr,
	}
	backend.pipeline_bind(cmd, pipeline)
	backend.pipeline_push(cmd, pipeline, {.VERTEX, .FRAGMENT}, &particle_pc)
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
	transforms := (^GpuTransform)(current_frame_data(engine).transforms_buffer.alloc_info.mapped_data)
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

	backend.pipeline_bind(cmd, shadow_map_pipeline)
	vk.CmdSetDepthBias(cmd, 1.25, 0, 1.75)

	frame := current_frame_data(engine)

	scene_data := (^SceneData)(current_frame_data(engine).scene_data_buffer.alloc_info.mapped_data)
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
			backend.pipeline_push(cmd, shadow_map_pipeline, {.VERTEX, .FRAGMENT}, &pc)
			vk.CmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, .UINT32)
			vk.CmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0)
		}
	}
}

draw_dir_shadow_casters :: proc(engine: ^Engine, cmd: vk.CommandBuffer, light_i: u32) {
	shadow_map_pipeline := get_pipeline(&engine.pipeline_registry, .Shadow_Directional)

	backend.pipeline_bind(cmd, shadow_map_pipeline)
	vk.CmdSetDepthBias(cmd, 1.25, 0, 1.75)

	frame := current_frame_data(engine)

	scene_data := (^SceneData)(current_frame_data(engine).scene_data_buffer.alloc_info.mapped_data)
	frustum := frustum_from_view_proj(scene_data.dir_light_view_proj[light_i])

	for &instance, slot_i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, u32(slot_i)) do continue

		model := &pool_get(&engine.model_system.models, instance.model)^

		if !volume_is_on_frustum(frustum, model.bounds, instance.transform) {
			continue
		}

		for &mesh in model.meshes {
			mat := pool_get(&engine.material_system.materials, mesh.material)
			if mat.alpha_mode == .Blend do continue

			pc := DirShadowPushConstants {
				scene_data       = frame.scene_data_buffer.ptr,
				vertex_buffer    = mesh.vertex_buffer.ptr,
				transform_buffer = frame.transforms_buffer.ptr,
				instance_index   = u32(slot_i),
				light_index      = light_i,
			}
			backend.pipeline_push(cmd, shadow_map_pipeline, {.VERTEX, .FRAGMENT}, &pc)
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
	backend.pipeline_bind(cmd, mesh_pipeline, .GRAPHICS, sets[:])

	frustum := frustum_create_from_camera(
		&engine.scene.camera,
		f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height),
	)

	draw_instance :: proc(engine: ^Engine, frustum: Frustum, cmd: vk.CommandBuffer, i: int, blend: bool) {
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
	backend.descriptor_write_image_info(&engine.vk_ctx, &engine.global_descriptor, 1, &image_info)
}

draw_skybox :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .Skybox)
	skybox_frame_idx := current_frame_res_index(engine)
	backend.pipeline_bind(cmd, pipeline, .GRAPHICS, {engine.global_descriptor.sets[skybox_frame_idx]})
	pc := SkyboxPushConstants {
		scene_data = current_frame_data(engine).scene_data_buffer.ptr,
	}
	backend.pipeline_push(cmd, pipeline, {.VERTEX, .FRAGMENT}, &pc)
	vk.CmdDraw(cmd, 3, 1, 0, 0)
}

draw_debug_shadow_map :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	DEBUG_SIZE :: 128

	pipeline := get_pipeline(&engine.pipeline_registry, .Debug_Shadow)
	begin_render_pass(engine, cmd, PassConfig{color_target = &engine.swapchain.render_targets.draw, load_op = .LOAD})
	backend.pipeline_bind(cmd, pipeline, .GRAPHICS, {engine.global_descriptor.sets[current_frame_res_index(engine)]})
	scene_data := (^SceneData)(current_frame_data(engine).scene_data_buffer.alloc_info.mapped_data)

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
		backend.pipeline_push(cmd, pipeline, {.FRAGMENT}, &debug_pc)
		vk.CmdDraw(cmd, 3, 1, 0, 0)
	}
	{
		viewport := vk.Viewport {
			x        = 6 * DEBUG_SIZE,
			y        = 0,
			width    = DEBUG_SIZE,
			height   = DEBUG_SIZE,
			minDepth = 0,
			maxDepth = 1,
		}
		scissor := vk.Rect2D {
			offset = {6 * DEBUG_SIZE, 0},
			extent = {DEBUG_SIZE, DEBUG_SIZE},
		}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)
		vk.CmdSetScissor(cmd, 0, 1, &scissor)
		debug_pc := DebugPC{scene_data.shadow_near, scene_data.shadow_far, 6, 0}
		backend.pipeline_push(cmd, pipeline, {.FRAGMENT}, &debug_pc)
		vk.CmdDraw(cmd, 3, 1, 0, 0)
	}
	end_render_pass(cmd)
}

draw_ui :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	pipeline := get_pipeline(&engine.pipeline_registry, .UI)
	backend.pipeline_bind(cmd, pipeline)
	vk.CmdDraw(cmd, 6, 1, 0, 0)
}

draw_scene :: proc(engine: ^Engine, cmd: vk.CommandBuffer) {
	// dispatch_particles(engine, cmd)

	shadow_light_count := min(int(engine.scene.point_light_count), MAX_SHADOW_LIGHTS)
	dir_shadow_light_count := min(int(engine.scene.directional_light_count), MAX_SHADOW_LIGHTS)

	// directional light shadow map
	backend.image_barrier(
		cmd,
		engine.dir_shadow_atlas.image,
		.Undefined,
		.Depth_Write,
		{.DEPTH},
		layer_count = MAX_SHADOW_LIGHTS,
	)

	for i in 0 ..< dir_shadow_light_count {
		begin_render_pass(
			engine,
			cmd,
			PassConfig {
				depth_target = &engine.dir_shadow_atlas.gpu,
				depth_view = engine.dir_shadow_atlas.layer_views[i],
				load_op = .CLEAR,
				store_depth = true,
				skip_depth_transition = true,
			},
		)
		draw_dir_shadow_casters(engine, cmd, u32(i))
		end_render_pass(cmd)
	}
	// Transition directional shadow atlas to read-only for the mesh pass
	backend.image_barrier(
		cmd,
		engine.dir_shadow_atlas.image,
		.Depth_Write,
		.Depth_Read,
		{.DEPTH},
		layer_count = MAX_SHADOW_LIGHTS,
	)

	// Always transition all MAX_SHADOW_LIGHTS*6 layers so unused layers are in the
	// expected layout when the mesh pass samples the descriptor.
	backend.image_barrier(
		cmd,
		engine.shadow_atlas.image,
		.Undefined,
		.Depth_Write,
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
					depth_target = &engine.shadow_atlas.gpu,
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

	backend.image_barrier(
		cmd,
		engine.shadow_atlas.image,
		.Depth_Write,
		.Depth_Read,
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
	current_frame_sync := backend.current_frame_sync(&engine.vk_ctx, engine.frame_index)
	current_frame_data := current_frame_data(engine)

	vk.ResetCommandPool(engine.vk_ctx.device, current_frame_sync.command_pool, {})

	cmd := current_frame_sync.command_buffer

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

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

	vk_check(vk.EndCommandBuffer(cmd))
}

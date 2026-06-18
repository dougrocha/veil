package graphics

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:time"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

initialize_vulkan :: proc(app: ^App) -> (ok: bool) {
	engine := &app.engine

	engine.start_time = time.now()
	engine.last_frame_time = engine.start_time
	engine.camera = camera_create({2, 2, 4}, yaw = -90, pitch = -15)
	engine.ambient_light = AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.15,
	}

	create_vulkan_instance(engine)
	app.engine.surface = create_vulkan_surface(app) or_return
	engine.physical_device = find_physical_device(engine) or_return
	engine.msaa_samples = get_max_usable_sample_count(engine)
	find_graphics_queue(engine) or_return
	create_logical_device(engine) or_return
	initialize_vma(engine)

	create_swapchain(engine, app.width, app.height)
	create_color_resources(engine)
	create_depth_resources(engine)
	create_draw_image(engine)

	create_shader_system(engine) or_return
	load_shader(engine, "mesh", {VERTEX_ENTRY, FRAGMENT_MAIN}) or_return
	load_shader(engine, "particle", {VERTEX_ENTRY, FRAGMENT_MAIN, COMPUTE_MAIN}) or_return
	create_descriptor_set_layout(engine)
	mesh_module := get_shader(engine, "mesh")
	particle_module := get_shader(engine, "particle")
	engine.pipeline = create_graphics_pipeline(engine, mesh_module)
	engine.particle_draw_pipeline = create_particle_draw_pipeline(engine, particle_module)
	engine.particle_pipeline = create_particle_pipeline(engine, particle_module)

	create_sync_resources(engine)
	create_command_buffers(engine)
	create_scene_data_buffer(engine)
	create_descriptor_pool(engine)
	create_descriptor_sets(engine)

	create_texture_system(engine, {max_textures_count = MAX_TEXTURES})
	create_material_system(engine, {max_material_count = MAX_MATERIALS})
	create_model_system(engine)
	create_particle_buffer(engine)

	return true
}

engine_shutdown :: proc(self: ^Engine) {
	vk.DeviceWaitIdle(self.device)

	destroy_texture_system(self)
	destroy_model_system(self)
	destroy_material_system(self)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		destroy_buffer(self, self.scene_data_buffers[i])
		destroy_buffer(self, self.particle_buffers[i])
	}

	vk.DestroyPipeline(self.device, self.particle_draw_pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(self.device, self.particle_draw_pipeline.layout, nil)
	vk.DestroyPipeline(self.device, self.particle_pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(self.device, self.particle_pipeline.layout, nil)

	vk.DestroyDescriptorPool(self.device, self.descriptor_pool, nil)
	vk.DestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, nil)

	vk.DestroyPipeline(self.device, self.pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(self.device, self.pipeline.layout, nil)

	destroy_shader_system(self)

	vk.DestroySemaphore(self.device, self.timeline_semaphore, nil)
	for &res in self.frame_resources {
		vk.DestroySemaphore(self.device, res.image_acquired_semaphore, nil)
		vk.DestroySemaphore(self.device, res.render_complete_semaphore, nil)
		vk.DestroyCommandPool(self.device, res.command_pool, nil)
		delete(res.deletion_queue.deletors)
	}
	cleanup_swapchain(self)
	vma.destroy_allocator(self.vma_allocator)

	vk.DestroyDevice(self.device, nil)
	vk.DestroySurfaceKHR(self.instance, self.surface, nil)
	vk.DestroyInstance(self.instance, nil)
}

engine_render :: proc(app: ^App) {
	// recreate swapchain
	if app.engine.require_swapchain_recreate {
		vk.DeviceWaitIdle(app.engine.device)
		cleanup_swapchain(&app.engine)
		create_swapchain(&app.engine, app.width, app.height)
		create_color_resources(&app.engine)
		create_depth_resources(&app.engine)
		create_draw_image(&app.engine)
		app.engine.require_swapchain_recreate = false
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
		vk_check(vk.WaitSemaphores(app.engine.device, &wait_info, max(u64)))
	}

	frame_res_index := app.engine.frame_index % MAX_FRAMES_IN_FLIGHT
	current_frame_res := &app.engine.frame_resources[frame_res_index]
	flush_deletion_queue(&current_frame_res.deletion_queue)

	// get the next swapchain image we can write too
	//
	// NOTE: purely chance, but your frame resources and swapchain count can be different
	// in our case, it was chance they are both two.
	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		app.engine.device,
		app.engine.swapchain,
		max(u64),
		current_frame_res.image_acquired_semaphore,
		0,
		&image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		app.engine.require_swapchain_recreate = true
		return
	} else if acquire_result == .SUBOPTIMAL_KHR {
		app.engine.require_swapchain_recreate = true
	}

	app.engine.next_signal_value += 1
	signal_value := app.engine.next_signal_value
	app.engine.frame_index += 1

	update_scene_data_buffer(&app.engine, frame_res_index)

	record_command_buffer(&app.engine, image_index, frame_res_index)

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
	vk_check(vk.QueueSubmit2(app.engine.graphics_queue, 1, &submit_info, 0))

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &current_frame_res.render_complete_semaphore,
		swapchainCount     = 1,
		pSwapchains        = &app.engine.swapchain,
		pImageIndices      = &image_index,
	}

	present_result := vk.QueuePresentKHR(app.engine.graphics_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR {
		app.engine.require_swapchain_recreate = true
	} else if present_result == .SUBOPTIMAL_KHR {
		app.engine.require_swapchain_recreate = true
	} else if present_result != .SUCCESS {
		log.errorf("QueuePresentKHR failed")
	}
}

record_command_buffer :: proc(engine: ^Engine, image_index: u32, frame_res_index: u64) {
	current_frame_res := &engine.frame_resources[frame_res_index]

	vk.ResetCommandPool(engine.device, current_frame_res.command_pool, {})

	cmd := current_frame_res.command_buffer

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	// {
	// 	vk.CmdBindPipeline(cmd, .COMPUTE, engine.particle_pipeline.pipeline)
	//
	// 	last_frame := (frame_res_index + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT
	// 	compute_pc := ParticlePushConstants {
	// 		particles_in  = engine.particle_buffers[last_frame].ptr,
	// 		particles_out = engine.particle_buffers[frame_res_index].ptr,
	// 		delta_time    = engine.delta_time,
	// 	}
	// 	vk.CmdPushConstants(
	// 		cmd,
	// 		engine.particle_pipeline.layout,
	// 		{.COMPUTE},
	// 		0,
	// 		size_of(ParticlePushConstants),
	// 		&compute_pc,
	// 	)
	//
	// 	vk.CmdDispatch(cmd, PARTICLE_COUNT / 256, 1, 1)
	//
	// 	barrier := vk.MemoryBarrier2 {
	// 		sType         = .MEMORY_BARRIER_2,
	// 		srcStageMask  = {.COMPUTE_SHADER},
	// 		srcAccessMask = {.SHADER_WRITE},
	// 		dstStageMask  = {.VERTEX_SHADER},
	// 		dstAccessMask = {.SHADER_READ},
	// 	}
	// 	dep_info := vk.DependencyInfo {
	// 		sType              = .DEPENDENCY_INFO,
	// 		memoryBarrierCount = 1,
	// 		pMemoryBarriers    = &barrier,
	// 	}
	// 	vk.CmdPipelineBarrier2(cmd, &dep_info)
	// }

	transition_image_layout(
		cmd,
		engine.color_image.image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR},
	)
	transition_image_layout(
		cmd,
		engine.draw_image.image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{},
		{.COLOR_ATTACHMENT_WRITE},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR_ATTACHMENT_OUTPUT},
		{.COLOR},
	)
	transition_image_layout(
		cmd,
		engine.depth_image.image,
		.UNDEFINED,
		.DEPTH_ATTACHMENT_OPTIMAL,
		{},
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.EARLY_FRAGMENT_TESTS},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
		{.DEPTH},
	)

	color_attach_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = engine.color_image.image_view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		resolveMode = {.AVERAGE},
		resolveImageView = engine.draw_image.image_view,
		resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {color = {float32 = {0.1, 0.1, 0.1, 1}}},
	}

	depth_attach_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = engine.depth_image.image_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {depthStencil = {depth = 1}},
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = engine.swapchain_extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attach_info,
		pDepthAttachment = &depth_attach_info,
	}

	vk.CmdBeginRendering(cmd, &rendering_info)
	{
		viewport := vk.Viewport {
			x        = 0,
			y        = 0,
			width    = f32(engine.swapchain_extent.width),
			height   = f32(engine.swapchain_extent.height),
			minDepth = 0,
			maxDepth = 1,
		}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)

		scissor := vk.Rect2D {
			offset = {x = 0, y = 0},
			extent = engine.swapchain_extent,
		}
		vk.CmdSetScissor(cmd, 0, 1, &scissor)

		vk.CmdBindPipeline(cmd, .GRAPHICS, engine.pipeline.pipeline)

		vk.CmdBindDescriptorSets(
			cmd,
			.GRAPHICS,
			engine.pipeline.layout,
			0,
			1,
			&engine.descriptor_sets[frame_res_index],
			0,
			nil,
		)

		transforms := (^Mat4x4)(engine.model_system.transforms_buffer.alloc_info.mapped_data)
		for instance, i in engine.model_system.instances {
			rot := linalg.matrix4_from_quaternion(instance.transform.rotation)
			translation := linalg.matrix4_translate(instance.transform.translation)
			scale := linalg.matrix4_scale(instance.transform.scale)

			mem.ptr_offset(transforms, i)^ = translation * rot * scale
		}

		for &instance, i in engine.model_system.instances {
			model := &engine.model_system.models[instance.model.handle]

			for &mesh in model.meshes {
				pc := PushConstants {
					scene_data       = engine.scene_data_buffers[frame_res_index].ptr,
					vertex_buffer    = mesh.vertex_address,
					material_buffer  = engine.material_system.buffer.ptr,
					transform_buffer = engine.model_system.transforms_buffer.ptr,
					material_index   = u32(mesh.material_index),
					instance_index   = u32(i),
				}

				vk.CmdPushConstants(cmd, engine.pipeline.layout, {.VERTEX, .FRAGMENT}, 0, size_of(PushConstants), &pc)
				vk.CmdBindIndexBuffer(cmd, mesh.index_buffer, 0, .UINT32)
				vk.CmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0)
			}
		}

		// {
		// 	particle_pc := ParticlePushConstants {
		// 		scene_data    = engine.scene_data_buffers[frame_res_index].ptr,
		// 		particles_out = engine.particle_buffers[frame_res_index].ptr,
		// 	}
		// 	vk.CmdBindPipeline(cmd, .GRAPHICS, engine.particle_draw_pipeline.pipeline)
		// 	vk.CmdPushConstants(cmd, engine.particle_draw_pipeline.layout, {.VERTEX, .FRAGMENT}, 0, size_of(ParticlePushConstants), &particle_pc)
		// 	vk.CmdDraw(cmd, PARTICLE_COUNT, 1, 0, 0)
		// }
	}
	vk.CmdEndRendering(cmd)

	transition_image_layout(
		cmd,
		engine.draw_image.image,
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
		engine.swapchain_images[image_index],
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
		engine.draw_image.image,
		engine.swapchain_images[image_index],
		engine.swapchain_extent,
		engine.swapchain_extent,
	)

	transition_image_layout(
		cmd,
		engine.swapchain_images[image_index],
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

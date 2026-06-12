package graphics

import "core:log"
import "core:math/linalg"
import "core:time"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

initialize_vulkan :: proc(app: ^App) -> (ok: bool) {
	engine := &app.engine

	engine.start_time = time.now()
	engine.last_frame_time = engine.start_time
	engine.camera = camera_create({2, 2, 2}, yaw = -135, pitch = -35)

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

	slang_init(engine) or_return
	create_shaders_slang(engine) or_return
	create_descriptor_set_layout(engine)
	engine.pipeline = create_graphics_pipeline(engine)

	create_sync_resources(engine)
	create_command_buffers(engine)
	create_scene_data_buffer(engine)
	create_descriptor_pool(engine)
	create_descriptor_sets(engine)

	create_default_texture(engine)

	return true
}

engine_shutdown :: proc(self: ^Engine) {
	vk.DeviceWaitIdle(self.device)

	for &t in self.textures {
		vk.DestroySampler(self.device, t.sampler, nil)
		vk.DestroyImageView(self.device, t.image_view, nil)
		vma.destroy_image(self.vma_allocator, t.image, t.allocation)
	}
	delete(self.textures)

	for &mesh in self.meshes {
		vma.destroy_buffer(self.vma_allocator, mesh.vertex_buffer, mesh.vertex_allocation)
		vma.destroy_buffer(self.vma_allocator, mesh.index_buffer, mesh.index_allocation)
	}
	delete(self.meshes)
	destroy_buffer(self, self.material_buffer)
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		destroy_buffer(self, self.scene_data_buffers[i])
	}

	vk.DestroyDescriptorPool(self.device, self.descriptor_pool, nil)
	vk.DestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, nil)

	vk.DestroyPipeline(self.device, self.pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(self.device, self.pipeline.layout, nil)

	vk.DestroyShaderModule(self.device, self.shader_module, nil)
	slang_cleanup(self)

	vk.DestroySemaphore(self.device, self.timeline_semaphore, nil)
	for &res in self.frame_resources {
		vk.DestroySemaphore(self.device, res.image_acquired_semaphore, nil)
		vk.DestroySemaphore(self.device, res.render_complete_semaphore, nil)
		vk.DestroyCommandPool(self.device, res.command_pool, nil)
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

	update_scene_data_buffer(&app.engine, frame_res_index)

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

	vk.ResetCommandPool(app.engine.device, current_frame_res.command_pool, {})

	cmd := current_frame_res.command_buffer

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	transition_image_layout(
		cmd,
		app.engine.color_image.image,
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
		app.engine.swapchain_images[image_index],
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
		app.engine.depth_image.image,
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
		imageView = app.engine.color_image.image_view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		resolveMode = {.AVERAGE},
		resolveImageView = app.engine.swapchain_image_view[image_index],
		resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {color = {float32 = {0.1, 0.1, 0.1, 1}}},
	}

	depth_attach_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = app.engine.depth_image.image_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {depthStencil = {depth = 1}},
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = app.engine.swapchain_extent},
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
			width    = f32(app.engine.swapchain_extent.width),
			height   = f32(app.engine.swapchain_extent.height),
			minDepth = 0,
			maxDepth = 1,
		}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)

		scissor := vk.Rect2D {
			offset = {x = 0, y = 0},
			extent = app.engine.swapchain_extent,
		}
		vk.CmdSetScissor(cmd, 0, 1, &scissor)

		vk.CmdBindPipeline(cmd, .GRAPHICS, app.engine.pipeline.pipeline)

		vk.CmdBindDescriptorSets(
			cmd,
			.GRAPHICS,
			app.engine.pipeline.layout,
			0,
			1,
			&app.engine.descriptor_sets[frame_res_index],
			0,
			nil,
		)

		for &mesh in app.engine.meshes {
			rot := linalg.matrix4_from_quaternion(mesh.transform.rotation)
			translation := linalg.matrix4_translate(mesh.transform.translation)
			scale := linalg.matrix4_scale(mesh.transform.scale)
			pc := PushConstants {
				scene_data              = app.engine.scene_data_buffers[frame_res_index].ptr,
				model                   = translation * rot * scale,
				vertex_buffer_address   = mesh.vertex_address,
				material_buffer_address = app.engine.material_buffer.ptr,
				material_index          = u32(mesh.material_index),
			}
			vk.CmdPushConstants(cmd, app.engine.pipeline.layout, {.VERTEX, .FRAGMENT}, 0, size_of(PushConstants), &pc)
			vk.CmdBindIndexBuffer(cmd, mesh.index_buffer, 0, .UINT32)
			vk.CmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0)
		}
	}
	vk.CmdEndRendering(cmd)

	present_layout_barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask = {},
		dstAccessMask = {},
		oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout = .PRESENT_SRC_KHR,
		image = app.engine.swapchain_images[image_index],
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}

	present_dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &present_layout_barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &present_dep_info)

	vk_check(vk.EndCommandBuffer(cmd))

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

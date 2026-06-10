package graphics

import "core:log"
import "core:math"
import "core:time"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

initialize_vulkan :: proc(app: ^App) -> (ok: bool) {
	self := &app.engine

	self.start_time = time.now()
	self.last_frame_time = self.start_time
	self.camera = camera_create({2, 2, 2})

	create_vulkan_instance(self)

	if !create_vulkan_surface(app) {
		log.errorf("Could not create a vulkan surface")
		return false
	}

	if self.physical_device = find_physical_device(self); self.physical_device == nil {
		log.errorf("Could not find a physical device")
		return false
	}
	self.msaa_samples = get_max_usable_sample_count(self)

	if !find_graphics_queue(self) {
		log.errorf("Unable to find a graphics queue")
		return false
	}

	if !create_logical_device(self) {
		log.errorf("Cannot create logical device")
		return false
	}

	initialize_vma(self)

	create_swapchain(self, app.width, app.height)

	if !slang_init(self) {
		log.errorf("Could not initialize Slang")
		return false
	}

	if !create_shaders_slang(self) {
		log.errorf("Could not create shaders")
		return false
	}

	create_descriptor_set_layout(self)

	if self.pipeline = create_graphics_pipeline(self); self.pipeline == 0 {
		log.errorf("Could not create graphics pipeline")
		return false
	}

	create_sync_resources(self)

	create_command_buffers(self)
	create_color_resources(self)
	create_depth_resources(self)
	create_texture_image(self)
	create_texture_image_view(self)
	create_texture_sampler(self)
	create_geometry_buffer(self)
	create_uniform_buffers(self)
	create_descriptor_pool(self)
	create_descriptor_sets(self)

	return true
}

engine_shutdown :: proc(self: ^Engine) {
	vk.DeviceWaitIdle(self.device)

	vk.DestroySampler(self.device, self.texture_sampler, nil)
	vk.DestroyImageView(self.device, self.texture_image_view, nil)
	vma.destroy_image(self.vma_allocator, self.texture_image, self.texture_image_allocation)

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vma.destroy_buffer(self.vma_allocator, self.uniform_buffers[i], self.uniform_buffer_allocations[i])
	}
	vma.destroy_buffer(self.vma_allocator, self.geometry_buffer, self.geometry_buffer_allocation)

	vk.DestroyDescriptorPool(self.device, self.descriptor_pool, nil)
	vk.DestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, nil)

	vk.DestroyPipeline(self.device, self.pipeline, nil)
	vk.DestroyPipelineLayout(self.device, self.pipeline_layout, nil)

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
	if app.engine.require_swapchain_recreate {
		vk.DeviceWaitIdle(app.engine.device)
		cleanup_swapchain(&app.engine)
		create_swapchain(&app.engine, app.width, app.height)
		create_color_resources(&app.engine)
		create_depth_resources(&app.engine)
		app.engine.require_swapchain_recreate = false
	}

	frame_res_index := app.engine.frame_index % MAX_FRAMES_IN_FLIGHT
	res := &app.engine.frame_resources[frame_res_index]

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

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		app.engine.device,
		app.engine.swapchain,
		max(u64),
		res.image_acquired_semaphore,
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

	vk.ResetCommandPool(app.engine.device, res.command_pool, {})

	cmd := res.command_buffer

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	transition_image_layout(
		cmd,
		app.engine.color_image,
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
		app.engine.depth_image,
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
		imageView = app.engine.color_image_view,
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
		imageView = app.engine.depth_image_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .DONT_CARE,
		clearValue = {depthStencil = {depth = 1}},
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {
			offset = {0, 0},
			extent = {width = app.engine.swapchain_width, height = app.engine.swapchain_height},
		},
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
			width    = f32(app.engine.swapchain_width),
			height   = f32(app.engine.swapchain_height),
			minDepth = 0,
			maxDepth = 1,
		}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)

		scissor := vk.Rect2D {
			offset = {x = 0, y = 0},
			extent = {width = app.engine.swapchain_width, height = app.engine.swapchain_height},
		}
		vk.CmdSetScissor(cmd, 0, 1, &scissor)

		vk.CmdBindPipeline(cmd, .GRAPHICS, app.engine.pipeline)

		offset: vk.DeviceSize = 0
		// vk.CmdBindVertexBuffers(cmd, 0, 1, &app.engine.geometry_buffer, &offset)
		vk.CmdBindIndexBuffer(cmd, app.engine.geometry_buffer, app.engine.index_buffer_offset, .UINT32)
		vk.CmdBindDescriptorSets(
			cmd,
			.GRAPHICS,
			app.engine.pipeline_layout,
			0,
			1,
			&app.engine.descriptor_sets[frame_res_index],
			0,
			nil,
		)

		// push constants
		elapsed := f32(time.duration_seconds(time.since(app.engine.start_time)))
		data := Vec4 {
			(math.sin_f32(elapsed) + 1.0) * 0.5,
			(math.sin_f32(elapsed + 2.094) + 1.0) * 0.5,
			(math.sin_f32(elapsed + 4.189) + 1.0) * 0.5,
			1.0,
		}
		pc := PushConstants {
			vertex_buffer_address = app.engine.geometry_buffer_address,
			data                  = data,
		}
		vk.CmdPushConstants(cmd, app.engine.pipeline_layout, {.VERTEX, .FRAGMENT}, 0, size_of(PushConstants), &pc)

		vk.CmdDrawIndexed(cmd, u32(len(app.engine.indices)), 1, 0, 0, 0)
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

	image_acquired_wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = res.image_acquired_semaphore,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}

	semaphore_signals := [2]vk.SemaphoreSubmitInfo {
		{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = res.render_complete_semaphore, stageMask = {.ALL_GRAPHICS}},
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

	update_uniform_buffer(&app.engine, frame_res_index)

	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &image_acquired_wait_info,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_submit_info,
		signalSemaphoreInfoCount = len(semaphore_signals),
		pSignalSemaphoreInfos    = &semaphore_signals[0],
	}

	vk_check(vk.QueueSubmit2(app.engine.graphics_queue, 1, &submit_info, 0))

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &res.render_complete_semaphore,
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


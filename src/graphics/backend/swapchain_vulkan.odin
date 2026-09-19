#+build linux

package backend

import vk "vendor:vulkan"

RenderTargets :: struct {
	color: GpuImage,
	depth: GpuImage,
	draw:  GpuImage,
	bloom: GpuImage,
}

Swapchain :: struct {
	handle:              vk.SwapchainKHR,
	images:              []vk.Image,
	require_recreate:    bool,
	extent:              vk.Extent2D,
	render_targets:      RenderTargets,
	current_image_index: u32,
}

swapchain_create :: proc(ctx: ^Context, width, height: u32) -> Swapchain {
	swapchain: Swapchain
	swapchain.extent = {width, height}

	surface_caps: vk.SurfaceCapabilitiesKHR
	vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &surface_caps))

	requested_image_count := max(2, surface_caps.minImageCount)
	if surface_caps.maxImageCount > 0 {
		requested_image_count = min(requested_image_count, surface_caps.maxImageCount)
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = ctx.surface,
		minImageCount    = u32(requested_image_count),
		imageFormat      = SWAPCHAIN_FORMAT,
		imageColorSpace  = .SRGB_NONLINEAR,
		imageExtent      = swapchain.extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = surface_caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .FIFO,
		clipped          = true,
	}
	vk_check(vk.CreateSwapchainKHR(ctx.device, &create_info, nil, &swapchain.handle))

	image_count: u32 = 0
	vk.GetSwapchainImagesKHR(ctx.device, swapchain.handle, &image_count, nil)
	swapchain.images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(ctx.device, swapchain.handle, &image_count, raw_data(swapchain.images))

	return swapchain
}

swapchain_destroy :: proc(ctx: ^Context, swapchain: ^Swapchain) {
	render_targets_destroy(ctx, &swapchain.render_targets)
	delete(swapchain.images)
	vk.DestroySwapchainKHR(ctx.device, swapchain.handle, nil)
}

render_target_create :: proc(
	ctx: ^Context,
	extent: vk.Extent3D,
	format: vk.Format,
	usage: ImageUsageFlags,
	samples: vk.SampleCountFlags = {._1},
) -> GpuImage {
	desc := image_desc_default(extent, format, usage)
	desc.samples = samples
	img := image_create(ctx, desc)

	view_desc := image_view_desc_default(img)
	img.image_view = image_view_create(ctx, img, view_desc)
	return img
}

render_targets_create :: proc(ctx: ^Context, extent: vk.Extent2D, msaa: vk.SampleCountFlags) -> RenderTargets {
	extent_3d := vk.Extent3D{extent.width, extent.height, 1}
	return RenderTargets {
		color = render_target_create(ctx, extent_3d, DRAW_FORMAT, {.Transient, .ColorAttachment}, samples = msaa),
		depth = render_target_create(ctx, extent_3d, DEPTH_FORMAT, {.DepthStencilAttachment}, samples = msaa),
		draw = render_target_create(
			ctx,
			extent_3d,
			DRAW_FORMAT,
			{.ColorAttachment, .TransferSrc, .TransferDst, .Storage},
		),
	}
}

render_targets_destroy :: proc(ctx: ^Context, targets: ^RenderTargets) {
	image_destroy(ctx, targets.color)
	image_destroy(ctx, targets.depth)
	image_destroy(ctx, targets.draw)
}

swapchain_acquire_next_image :: proc(
	ctx: ^Context,
	swapchain: ^Swapchain,
	frame_sync: ^FrameSync,
) -> AcquireImageResult {
	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		ctx.device,
		swapchain.handle,
		max(u64),
		frame_sync.image_acquired_semaphore,
		0,
		&image_index,
	)
	swapchain.current_image_index = image_index

	#partial switch acquire_result {
	case .SUCCESS:
		return .Success
	case .ERROR_OUT_OF_DATE_KHR:
		return .OutOfDate
	case .SUBOPTIMAL_KHR:
		return .Suboptimal
	case:
		return .OutOfDate
	}
}

present_blit :: proc(ctx: ^Context, cmd: CommandBuffer, swapchain: ^Swapchain) {
	image_barrier(cmd, &swapchain.render_targets.draw, .Transfer_Src, ImageAspectFlags{.Color})
	image_barrier_raw(
		cmd,
		swapchain.images[swapchain.current_image_index],
		.Undefined,
		.Transfer_Dst,
		image_aspect_to_vk({.Color}),
	)
	copy_image_to_image(
		cmd,
		swapchain.render_targets.draw.image,
		swapchain.images[swapchain.current_image_index],
		swapchain.extent,
		swapchain.extent,
	)
	image_barrier_raw(
		cmd,
		swapchain.images[swapchain.current_image_index],
		.Transfer_Dst,
		.Present,
		image_aspect_to_vk({.Color}),
	)
}

queue_present_frame :: proc(
	ctx: ^Context,
	cmd: CommandBuffer,
	swapchain: ^Swapchain,
	frame_sync: ^FrameSync,
) -> PresentFrameResult {
	sem := frame_sync.render_complete_semaphore
	handle := swapchain.handle
	idx := swapchain.current_image_index

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &sem,
		swapchainCount     = 1,
		pSwapchains        = &handle,
		pImageIndices      = &idx,
	}

	present_result := vk.QueuePresentKHR(ctx.graphics_queue, &present_info)

	#partial switch present_result {
	case .SUCCESS:
		return .Success
	case .ERROR_OUT_OF_DATE_KHR:
		return .OutOfDate
	case .SUBOPTIMAL_KHR:
		return .Suboptimal
	case:
		return .Error
	}
}

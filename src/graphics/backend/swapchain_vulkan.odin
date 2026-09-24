#+build linux

package backend

import "core:log"

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
	// Signaled by the frame's submit, waited on by present. One per image, not per frame in
	// flight: the presentation engine can still hold it after that frame's fence has passed.
	present_semaphores:  []vk.Semaphore,
	require_recreate:    bool,
	extent:              vk.Extent2D,
	render_targets:      RenderTargets,
	current_image_index: u32,
}

// Creates the swapchain and the render targets sized to it; swapchain_destroy frees both.
swapchain_create :: proc(ctx: ^Context, width, height: u32) -> Swapchain {
	return swapchain_build(ctx, width, height, 0)
}

// Replaces the swapchain, handing the old one to the driver as oldSwapchain so it can reuse
// resources. The caller must ensure no frame is still using the old swapchain or its targets.
swapchain_recreate :: proc(ctx: ^Context, swapchain: ^Swapchain, width, height: u32) {
	new_swapchain := swapchain_build(ctx, width, height, swapchain.handle)
	swapchain_destroy(ctx, swapchain)
	swapchain^ = new_swapchain
}

@(private = "file")
swapchain_build :: proc(ctx: ^Context, width, height: u32, old_handle: vk.SwapchainKHR) -> Swapchain {
	swapchain: Swapchain

	surface_caps: vk.SurfaceCapabilitiesKHR
	vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface, &surface_caps))

	// A defined currentExtent must be used as-is; 0xFFFFFFFF means the surface takes our size.
	if surface_caps.currentExtent.width != max(u32) {
		swapchain.extent = surface_caps.currentExtent
	} else {
		swapchain.extent = {
			clamp(width, surface_caps.minImageExtent.width, surface_caps.maxImageExtent.width),
			clamp(height, surface_caps.minImageExtent.height, surface_caps.maxImageExtent.height),
		}
	}

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
		oldSwapchain     = old_handle,
	}
	vk_check(vk.CreateSwapchainKHR(ctx.device, &create_info, nil, &swapchain.handle))

	image_count: u32 = 0
	vk.GetSwapchainImagesKHR(ctx.device, swapchain.handle, &image_count, nil)
	swapchain.images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(ctx.device, swapchain.handle, &image_count, raw_data(swapchain.images))

	swapchain.present_semaphores = make([]vk.Semaphore, image_count)
	for &sem in swapchain.present_semaphores {
		sem = binary_semaphore_create(ctx)
	}

	swapchain.render_targets = render_targets_create(ctx, swapchain.extent, ctx.msaa_samples)
	return swapchain
}

swapchain_destroy :: proc(ctx: ^Context, swapchain: ^Swapchain) {
	render_targets_destroy(ctx, &swapchain.render_targets)
	for sem in swapchain.present_semaphores {
		vk.DestroySemaphore(ctx.device, sem, nil)
	}
	delete(swapchain.present_semaphores)
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
	case .NOT_READY, .TIMEOUT:
		return .NotReady
	case:
		// DEVICE_LOST, SURFACE_LOST, OOM: recreating the swapchain won't fix these.
		log.panicf("vkAcquireNextImageKHR failed: %v", acquire_result)
	}
}

// First transition of a just-acquired swapchain image. The source is UNDEFINED (the previous
// contents are discarded on purpose; the blit overwrites the whole image), but not "no prior
// access": the presentation engine may still be reading it until the acquire semaphore wait.
// srcStage = SWAPCHAIN_FIRST_USE_STAGE chains this transition to that wait.
@(private = "file")
swapchain_acquire_barrier :: proc(cmd: CommandBuffer, image: vk.Image, dst: ImageStateKind) {
	dst := IMAGE_STATES[dst]
	barrier := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = SWAPCHAIN_FIRST_USE_STAGE,
		srcAccessMask       = {},
		oldLayout           = .UNDEFINED,
		dstStageMask        = dst.stage,
		dstAccessMask       = dst.access,
		newLayout           = dst.layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = image,
		subresourceRange    = {{.COLOR}, 0, 1, 0, 1},
	}
	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(vk.CommandBuffer(cmd), &dep_info)
}

present_blit :: proc(ctx: ^Context, cmd: CommandBuffer, swapchain: ^Swapchain) {
	image_barrier(cmd, &swapchain.render_targets.draw, .Transfer_Src, ImageAspectFlags{.Color})
	swapchain_acquire_barrier(cmd, swapchain.images[swapchain.current_image_index], .Transfer_Dst)
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
	sem := swapchain.present_semaphores[swapchain.current_image_index]
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
		// The present may not have been queued, leaving the present semaphore's state unknown;
		// nothing here is safely recoverable.
		log.panicf("vkQueuePresentKHR failed: %v", present_result)
	}
}

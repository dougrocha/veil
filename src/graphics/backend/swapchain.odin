package backend

import vk "vendor:vulkan"

RenderTargets :: struct {
	color: GpuImage,
	depth: GpuImage,
	draw:  GpuImage,
}

Swapchain :: struct {
	handle:           vk.SwapchainKHR,
	images:           []vk.Image,
	require_recreate: bool,
	extent:           vk.Extent2D,
	render_targets:   RenderTargets,
}

swapchain_create :: proc(ctx: ^VulkanContext, width, height: u32) -> Swapchain {
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

swapchain_destroy :: proc(ctx: ^VulkanContext, swapchain: ^Swapchain) {
	render_targets_destroy(ctx, &swapchain.render_targets)
	delete(swapchain.images)
	vk.DestroySwapchainKHR(ctx.device, swapchain.handle, nil)
}

render_target_create :: proc(
	ctx: ^VulkanContext,
	extent: vk.Extent3D,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	samples: vk.SampleCountFlags = {._1},
) -> GpuImage {
	desc := image_desc_default(extent, format, usage)
	desc.samples = samples
	img := image_create(ctx, desc)

	view_desc := image_view_desc_default(img)
	img.image_view = image_view_create(ctx, img, view_desc)
	return img
}

render_targets_create :: proc(ctx: ^VulkanContext, extent: vk.Extent2D, msaa: vk.SampleCountFlags) -> RenderTargets {
	extent_3d := vk.Extent3D{extent.width, extent.height, 1}
	return RenderTargets {
		color = render_target_create(
			ctx,
			extent_3d,
			DRAW_FORMAT,
			{.TRANSIENT_ATTACHMENT, .COLOR_ATTACHMENT},
			samples = msaa,
		),
		depth = render_target_create(ctx, extent_3d, DEPTH_FORMAT, {.DEPTH_STENCIL_ATTACHMENT}, samples = msaa),
		draw = render_target_create(
			ctx,
			extent_3d,
			DRAW_FORMAT,
			{.COLOR_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST, .STORAGE},
		),
	}
}

render_targets_destroy :: proc(ctx: ^VulkanContext, targets: ^RenderTargets) {
	image_destroy(ctx, targets.color)
	image_destroy(ctx, targets.depth)
	image_destroy(ctx, targets.draw)
}

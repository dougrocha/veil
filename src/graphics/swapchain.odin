package graphics

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

swapchain_create :: proc(self: ^Engine, width, height: u32) {
	self.swapchain.extent = {width, height}

	surface_caps: vk.SurfaceCapabilitiesKHR
	vk_check(
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(self.vk_ctx.physical_device, self.vk_ctx.surface, &surface_caps),
	)

	requested_image_count := max(2, surface_caps.minImageCount)
	if surface_caps.maxImageCount > 0 {
		requested_image_count = min(requested_image_count, surface_caps.maxImageCount)
	}

	swapchain_create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = self.vk_ctx.surface,
		minImageCount    = u32(requested_image_count),
		imageFormat      = SWAPCHAIN_FORMAT,
		imageColorSpace  = .SRGB_NONLINEAR,
		imageExtent      = self.swapchain.extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = surface_caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .FIFO,
		clipped          = true,
	}

	vk_check(vk.CreateSwapchainKHR(self.vk_ctx.device, &swapchain_create_info, nil, &self.swapchain.handle))

	image_count: u32 = 0
	vk.GetSwapchainImagesKHR(self.vk_ctx.device, self.swapchain.handle, &image_count, nil)
	self.swapchain.images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(self.vk_ctx.device, self.swapchain.handle, &image_count, raw_data(self.swapchain.images))

}

swapchain_destroy :: proc(self: ^Engine) {
	render_targets_destroy(&self.vk_ctx, &self.swapchain.render_targets)
	delete(self.swapchain.images)
	vk.DestroySwapchainKHR(self.vk_ctx.device, self.swapchain.handle, nil)
}

render_target_create :: proc(
	ctx: ^VulkanContext,
	extent: vk.Extent3D,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	aspect: vk.ImageAspectFlags,
	samples: vk.SampleCountFlags = {._1},
) -> GpuImage {
	img := image_create(ctx, extent, format, usage, samples = samples)
	img.image_view = image_view_create(ctx, img.image, format, aspect)
	return img
}

render_targets_create :: proc(ctx: ^VulkanContext, extent: vk.Extent2D, msaa: vk.SampleCountFlags) -> RenderTargets {
	extent_3d := vk.Extent3D{extent.width, extent.height, 1}

	targets := RenderTargets {
		color = render_target_create(
			ctx,
			extent_3d,
			DRAW_FORMAT,
			{.TRANSIENT_ATTACHMENT, .COLOR_ATTACHMENT},
			{.COLOR},
			samples = msaa,
		),
		depth = render_target_create(
			ctx,
			extent_3d,
			DEPTH_FORMAT,
			{.DEPTH_STENCIL_ATTACHMENT},
			{.DEPTH},
			samples = msaa,
		),
		draw  = render_target_create(
			ctx,
			extent_3d,
			DRAW_FORMAT,
			{.COLOR_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST, .STORAGE},
			{.COLOR},
		),
	}

	return targets
}

render_targets_destroy :: proc(ctx: ^VulkanContext, targets: ^RenderTargets) {
	destroy_image(ctx, targets.color)
	destroy_image(ctx, targets.depth)
	destroy_image(ctx, targets.draw)
}

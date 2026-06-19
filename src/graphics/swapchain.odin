package graphics

import vk "vendor:vulkan"

create_swapchain :: proc(self: ^Engine, width, height: u32) {
	self.swapchain_extent = {width, height}

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
		imageExtent      = self.swapchain_extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT, .TRANSFER_DST},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = surface_caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .FIFO,
		clipped          = true,
	}

	vk_check(vk.CreateSwapchainKHR(self.vk_ctx.device, &swapchain_create_info, nil, &self.swapchain))

	image_count: u32 = 0
	vk.GetSwapchainImagesKHR(self.vk_ctx.device, self.swapchain, &image_count, nil)
	self.swapchain_images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(self.vk_ctx.device, self.swapchain, &image_count, raw_data(self.swapchain_images))
	self.swapchain_image_view = make([]vk.ImageView, image_count)

	for i in 0 ..< len(self.swapchain_images) {
		self.swapchain_image_view[i] = create_image_view(
			&self.vk_ctx,
			self.swapchain_images[i],
			SWAPCHAIN_FORMAT,
			{.COLOR},
		)
	}

}

cleanup_swapchain :: proc(self: ^Engine) {
	destroy_image(&self.vk_ctx, self.color_image)
	destroy_image(&self.vk_ctx, self.depth_image)
	destroy_image(&self.vk_ctx, self.draw_image)

	for view in self.swapchain_image_view {
		vk.DestroyImageView(self.vk_ctx.device, view, nil)
	}
	delete(self.swapchain_images)
	delete(self.swapchain_image_view)

	vk.DestroySwapchainKHR(self.vk_ctx.device, self.swapchain, nil)
}

create_color_resources :: proc(engine: ^Engine) {
	engine.color_image = create_image(
		&engine.vk_ctx,
		{engine.swapchain_extent.width, engine.swapchain_extent.height, 1},
		DRAW_FORMAT,
		{.TRANSIENT_ATTACHMENT, .COLOR_ATTACHMENT},
		samples = engine.vk_ctx.msaa_samples,
	)
	engine.color_image.image_view = create_image_view(&engine.vk_ctx, engine.color_image.image, DRAW_FORMAT, {.COLOR})
}

create_depth_resources :: proc(engine: ^Engine) {
	engine.depth_image = create_image(
		&engine.vk_ctx,
		{engine.swapchain_extent.width, engine.swapchain_extent.height, 1},
		DEPTH_FORMAT,
		{.DEPTH_STENCIL_ATTACHMENT},
		samples = engine.vk_ctx.msaa_samples,
	)
	engine.depth_image.image_view = create_image_view(&engine.vk_ctx, engine.depth_image.image, DEPTH_FORMAT, {.DEPTH})
}

create_draw_image :: proc(engine: ^Engine) {
	engine.draw_image = create_image(
		&engine.vk_ctx,
		{engine.swapchain_extent.width, engine.swapchain_extent.height, 1},
		DRAW_FORMAT,
		{.COLOR_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST, .STORAGE},
	)
	engine.draw_image.image_view = create_image_view(&engine.vk_ctx, engine.draw_image.image, DRAW_FORMAT, {.COLOR})
}


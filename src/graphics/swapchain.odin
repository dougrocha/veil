package graphics

import vk "vendor:vulkan"

Swapchain :: struct {
	handle:           vk.SwapchainKHR,
	images:           []vk.Image,
	image_views:      []vk.ImageView,
	require_recreate: bool,
	extent:           vk.Extent2D,
	depth_image:      Texture,
	color_image:      Texture,
	draw_image:       Texture,
}

create_swapchain :: proc(self: ^Engine, width, height: u32) {
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
	self.swapchain.image_views = make([]vk.ImageView, image_count)

	for i in 0 ..< len(self.swapchain.images) {
		self.swapchain.image_views[i] = image_view_create(
			&self.vk_ctx,
			self.swapchain.images[i],
			SWAPCHAIN_FORMAT,
			{.COLOR},
		)
	}

}

cleanup_swapchain :: proc(self: ^Engine) {
	texture_destroy(&self.vk_ctx, self.swapchain.color_image)
	texture_destroy(&self.vk_ctx, self.swapchain.depth_image)
	texture_destroy(&self.vk_ctx, self.swapchain.draw_image)

	for view in self.swapchain.image_views {
		vk.DestroyImageView(self.vk_ctx.device, view, nil)
	}
	delete(self.swapchain.images)
	delete(self.swapchain.image_views)

	vk.DestroySwapchainKHR(self.vk_ctx.device, self.swapchain.handle, nil)
}

create_color_resources :: proc(engine: ^Engine) {
	engine.swapchain.color_image.gpu = image_create(
		&engine.vk_ctx,
		{engine.swapchain.extent.width, engine.swapchain.extent.height, 1},
		DRAW_FORMAT,
		{.TRANSIENT_ATTACHMENT, .COLOR_ATTACHMENT},
		samples = engine.vk_ctx.msaa_samples,
	)
	engine.swapchain.color_image.image_view = image_view_create(
		&engine.vk_ctx,
		engine.swapchain.color_image.image,
		DRAW_FORMAT,
		{.COLOR},
	)
	engine.swapchain.color_image.flags = {.WRITABLE, .EXTERNAL_LIFETIME}
}

create_depth_resources :: proc(engine: ^Engine) {
	engine.swapchain.depth_image.gpu = image_create(
		&engine.vk_ctx,
		{engine.swapchain.extent.width, engine.swapchain.extent.height, 1},
		DEPTH_FORMAT,
		{.DEPTH_STENCIL_ATTACHMENT},
		samples = engine.vk_ctx.msaa_samples,
	)
	engine.swapchain.depth_image.image_view = image_view_create(
		&engine.vk_ctx,
		engine.swapchain.depth_image.image,
		DEPTH_FORMAT,
		{.DEPTH},
	)
	engine.swapchain.depth_image.flags = {.WRITABLE, .EXTERNAL_LIFETIME}
}

create_draw_image :: proc(engine: ^Engine) {
	engine.swapchain.draw_image.gpu = image_create(
		&engine.vk_ctx,
		{engine.swapchain.extent.width, engine.swapchain.extent.height, 1},
		DRAW_FORMAT,
		{.COLOR_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST, .STORAGE},
	)
	engine.swapchain.draw_image.image_view = image_view_create(
		&engine.vk_ctx,
		engine.swapchain.draw_image.image,
		DRAW_FORMAT,
		{.COLOR},
	)
	engine.swapchain.draw_image.flags = {.WRITABLE, .EXTERNAL_LIFETIME}
}

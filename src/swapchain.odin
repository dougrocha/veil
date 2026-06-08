package main

import vma "shared:odin-vma"
import vk "vendor:vulkan"

create_swapchain :: proc(self: ^Engine, width, height: u32) {
	self.swapchain_width = width
	self.swapchain_height = height

	surface_caps: vk.SurfaceCapabilitiesKHR
	vk_check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &surface_caps))

	requested_image_count := max(2, surface_caps.minImageCount)
	if surface_caps.maxImageCount > 0 {
		requested_image_count = min(requested_image_count, surface_caps.maxImageCount)
	}

	swapchain_create_info := vk.SwapchainCreateInfoKHR {
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = self.surface,
		minImageCount = u32(requested_image_count),
		imageFormat = SWAPCHAIN_FORMAT,
		imageColorSpace = .SRGB_NONLINEAR,
		imageExtent = {width = self.swapchain_width, height = self.swapchain_height},
		imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform = surface_caps.currentTransform,
		compositeAlpha = {.OPAQUE},
		presentMode = .FIFO,
		clipped = true,
	}

	vk_check(vk.CreateSwapchainKHR(self.device, &swapchain_create_info, nil, &self.swapchain))

	// ask for swapchain images
	image_count: u32 = 0
	vk.GetSwapchainImagesKHR(self.device, self.swapchain, &image_count, nil)
	self.swapchain_images = make([]vk.Image, image_count)
	vk.GetSwapchainImagesKHR(self.device, self.swapchain, &image_count, raw_data(self.swapchain_images))
	self.swapchain_image_view = make([]vk.ImageView, image_count)

	for i in 0 ..< len(self.swapchain_images) {
		create_image_view(self, self.swapchain_images[i], SWAPCHAIN_FORMAT, {.COLOR}, &self.swapchain_image_view[i])
	}

	// setup semaphores
	self.render_complete_semaphores = make([]vk.Semaphore, len(self.swapchain_images))
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	for &semaphore in self.render_complete_semaphores {
		vk_check(vk.CreateSemaphore(self.device, &semaphore_info, nil, &semaphore))
	}

	depth_create_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = DEPTH_FORMAT,
		extent = {width = self.swapchain_width, height = self.swapchain_height, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		usage = {.DEPTH_STENCIL_ATTACHMENT},
		initialLayout = .UNDEFINED,
	}

	alloc_info := vma.Allocation_Create_Info {
		flags = {.Dedicated_Memory},
		usage = .Auto,
	}
	vk_check(
		vma.create_image(
			self.vma_allocator,
			depth_create_info,
			alloc_info,
			&self.depth_image,
			&self.depth_image_allocation,
			nil,
		),
	)

	create_image_view(self, self.depth_image, DEPTH_FORMAT, {.DEPTH}, &self.depth_image_view)
}

cleanup_swapchain :: proc(self: ^Engine) {
	vk.DestroyImageView(self.device, self.depth_image_view, nil)
	vma.destroy_image(self.vma_allocator, self.depth_image, self.depth_image_allocation)

	for view in self.swapchain_image_view {
		vk.DestroyImageView(self.device, view, nil)
	}
	for sem in self.render_complete_semaphores {
		vk.DestroySemaphore(self.device, sem, nil)
	}

	delete(self.swapchain_images)
	delete(self.swapchain_image_view)
	delete(self.render_complete_semaphores)

	vk.DestroySwapchainKHR(self.device, self.swapchain, nil)
}


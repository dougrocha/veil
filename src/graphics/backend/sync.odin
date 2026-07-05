package backend

import vk "vendor:vulkan"

FrameSync :: struct {
	command_pool:              vk.CommandPool,
	command_buffer:            vk.CommandBuffer,
	image_acquired_semaphore:  vk.Semaphore,
	render_complete_semaphore: vk.Semaphore,
}

frame_sync_create :: proc(ctx: ^VulkanContext) {
	ctx.timeline_semaphore = timeline_semaphore_create(ctx)

	for &sync in ctx.frame_sync {
		sync.command_pool = command_pool_create(ctx)
		sync.command_buffer = command_buffer_allocate(ctx, sync.command_pool)
		sync.image_acquired_semaphore = binary_semaphore_create(ctx)
		sync.render_complete_semaphore = binary_semaphore_create(ctx)
	}
}

frame_sync_destroy :: proc(ctx: ^VulkanContext) {
	for &sync in ctx.frame_sync {
		vk.DestroySemaphore(ctx.device, sync.image_acquired_semaphore, nil)
		vk.DestroySemaphore(ctx.device, sync.render_complete_semaphore, nil)
		vk.DestroyCommandPool(ctx.device, sync.command_pool, nil)
	}

	vk.DestroySemaphore(ctx.device, ctx.timeline_semaphore, nil)
}

current_frame_sync :: proc(ctx: ^VulkanContext, frame_index: u64) -> ^FrameSync {
	return &ctx.frame_sync[frame_index % MAX_FRAMES_IN_FLIGHT]
}

upload_pool_create :: proc(ctx: ^VulkanContext) {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.gfx_queue_fam_idx,
	}
	vk_check(vk.CreateCommandPool(ctx.device, &pool_info, nil, &ctx.upload_pool))
}

command_pool_create :: proc(ctx: ^VulkanContext, flags: vk.CommandPoolCreateFlags = {}) -> vk.CommandPool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = ctx.gfx_queue_fam_idx,
		flags            = flags,
	}

	command_pool: vk.CommandPool
	vk_check(vk.CreateCommandPool(ctx.device, &pool_info, nil, &command_pool))
	return command_pool
}

command_buffer_allocate :: proc(ctx: ^VulkanContext, pool: vk.CommandPool) -> vk.CommandBuffer {
	cmd_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	command_buffer: vk.CommandBuffer
	vk_check(vk.AllocateCommandBuffers(ctx.device, &cmd_alloc_info, &command_buffer))
	return command_buffer
}

timeline_semaphore_create :: proc(ctx: ^VulkanContext, initial_value: u64 = 0) -> vk.Semaphore {
	type_info := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
		initialValue  = initial_value,
	}
	info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &type_info,
	}
	sem: vk.Semaphore
	vk_check(vk.CreateSemaphore(ctx.device, &info, nil, &sem))
	return sem
}

binary_semaphore_create :: proc(ctx: ^VulkanContext) -> vk.Semaphore {
	info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	sem: vk.Semaphore
	vk_check(vk.CreateSemaphore(ctx.device, &info, nil, &sem))
	return sem
}

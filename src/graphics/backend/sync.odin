package backend

import vk "vendor:vulkan"

AcquireImageResult :: enum {
	Success,
	OutOfDate,
	Suboptimal,
	// No image this frame, but nothing is stale: skip the frame and try again.
	// Not a reason to rebuild anything.
	NotReady,
}

PresentFrameResult :: enum {
	Success,
	OutOfDate,
	Suboptimal,
}

FrameSync :: struct {
	command_pool:             vk.CommandPool,
	command_buffer:           CommandBuffer,
	image_acquired_semaphore: vk.Semaphore,
}

// Stage of the first operation on an acquired swapchain image (present_blit's transition + blit).
// The acquire semaphore is waited at this stage and swapchain_acquire_barrier chains to it, so it
// must cover that first operation: change it (e.g. to COLOR_ATTACHMENT_OUTPUT) if the swapchain
// image is ever rendered to directly.
SWAPCHAIN_FIRST_USE_STAGE :: vk.PipelineStageFlags2{.TRANSFER}

frame_sync_create :: proc(ctx: ^Context) {
	ctx.timeline_semaphore = timeline_semaphore_create(ctx)

	for &sync in ctx.frame_sync {
		sync.command_pool = command_pool_create(ctx)
		sync.command_buffer = command_buffer_allocate(ctx, sync.command_pool)
		sync.image_acquired_semaphore = binary_semaphore_create(ctx)
	}
}

frame_sync_destroy :: proc(ctx: ^Context) {
	for &sync in ctx.frame_sync {
		vk.DestroySemaphore(ctx.device, sync.image_acquired_semaphore, nil)
		vk.DestroyCommandPool(ctx.device, sync.command_pool, nil)
	}

	vk.DestroySemaphore(ctx.device, ctx.timeline_semaphore, nil)
}

current_frame_sync :: proc(ctx: ^Context, frame_index: u64) -> ^FrameSync {
	return &ctx.frame_sync[frame_index % MAX_FRAMES_IN_FLIGHT]
}

frame_command_buffer_begin :: proc(ctx: ^Context, frame_sync: ^FrameSync) -> CommandBuffer {
	return frame_sync.command_buffer
}

upload_pool_create :: proc(ctx: ^Context) {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = ctx.gfx_queue_fam_idx,
	}
	vk_check(vk.CreateCommandPool(ctx.device, &pool_info, nil, &ctx.upload_pool))
}

command_pool_create :: proc(ctx: ^Context, flags: vk.CommandPoolCreateFlags = {}) -> vk.CommandPool {
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = ctx.gfx_queue_fam_idx,
		flags            = flags,
	}

	command_pool: vk.CommandPool
	vk_check(vk.CreateCommandPool(ctx.device, &pool_info, nil, &command_pool))
	return command_pool
}

command_buffer_allocate :: proc(ctx: ^Context, pool: vk.CommandPool) -> CommandBuffer {
	cmd_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	command_buffer: vk.CommandBuffer
	vk_check(vk.AllocateCommandBuffers(ctx.device, &cmd_alloc_info, &command_buffer))
	return CommandBuffer{handle = command_buffer, ctx = ctx}
}

timeline_semaphore_create :: proc(ctx: ^Context, initial_value: u64 = 0) -> vk.Semaphore {
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

binary_semaphore_create :: proc(ctx: ^Context) -> vk.Semaphore {
	info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	sem: vk.Semaphore
	vk_check(vk.CreateSemaphore(ctx.device, &info, nil, &sem))
	return sem
}

// Frame N signals the timeline with N + 1. Before reusing this frame's slot, wait for the
// frame that last used it (N - MAX_FRAMES_IN_FLIGHT) to finish.
frame_wait_before_render :: proc(ctx: ^Context, frame_index: u64) {
	if frame_index >= MAX_FRAMES_IN_FLIGHT {
		wait_value := frame_index - MAX_FRAMES_IN_FLIGHT + 1
		wait_info := vk.SemaphoreWaitInfo {
			sType          = .SEMAPHORE_WAIT_INFO,
			semaphoreCount = 1,
			pSemaphores    = &ctx.timeline_semaphore,
			pValues        = &wait_value,
		}
		vk_check(vk.WaitSemaphores(ctx.device, &wait_info, max(u64)))
	}
}

queue_submit_frame :: proc(
	ctx: ^Context,
	cmd: CommandBuffer,
	swapchain: ^Swapchain,
	frame_sync: ^FrameSync,
	signal_value: u64,
) {
	image_acquired_wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = frame_sync.image_acquired_semaphore,
		stageMask = SWAPCHAIN_FIRST_USE_STAGE,
	}

	semaphore_signals := [2]vk.SemaphoreSubmitInfo {
		{
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = swapchain.present_semaphores[swapchain.current_image_index],
			// Must stay ALL_COMMANDS: the final Transfer_Dst -> Present barrier has dstStage NONE, so its
			// layout transition is only ordered before this signal when the signal covers all stages.
			// Narrowing to ALL_TRANSFER brings back PRESENT_AFTER_WRITE under sync validation.
			stageMask = {.ALL_COMMANDS},
		},
		{
			sType = .SEMAPHORE_SUBMIT_INFO,
			semaphore = ctx.timeline_semaphore,
			value = signal_value,
			stageMask = {.ALL_COMMANDS},
		},
	}

	cmd_submit_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd.handle,
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

	vk_check(vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, 0))
}

package backend

import vk "vendor:vulkan"

begin_immediate_submit :: proc(ctx: ^VulkanContext) -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.upload_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	cmd: vk.CommandBuffer
	vk_check(vk.AllocateCommandBuffers(ctx.device, &alloc_info, &cmd))
	vk_check(
		vk.BeginCommandBuffer(
			cmd,
			&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)
	return cmd
}

end_immediate_submit :: proc(ctx: ^VulkanContext, cmd: vk.CommandBuffer) {
	cmd := cmd
	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}
	submit_info := vk.SubmitInfo2 {
		sType                  = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &cmd_info,
	}

	vk_check(vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, 0))
	vk_check(vk.QueueWaitIdle(ctx.graphics_queue))
	vk.FreeCommandBuffers(ctx.device, ctx.upload_pool, 1, &cmd)
}

// idea from https://github.com/wrapperup/cool-engine-odin
@(deferred_in_out = end_immediate_submit)
immediate_submit :: proc(ctx: ^VulkanContext) -> (cmd: vk.CommandBuffer) {
	return begin_immediate_submit(ctx)
}

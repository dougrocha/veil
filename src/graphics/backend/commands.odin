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

end_immediate_submit :: proc(ctx: ^VulkanContext, cmd: CommandBuffer) {
	cmd := vk.CommandBuffer(cmd)
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
immediate_submit :: proc(ctx: ^VulkanContext) -> (cmd: CommandBuffer) {
	return CommandBuffer(begin_immediate_submit(ctx))
}

cmd_begin_recording :: proc(ctx: ^VulkanContext, cmd: CommandBuffer, frame_index: u64) {
	frame_sync := current_frame_sync(ctx, frame_index)
	vk.ResetCommandPool(ctx.device, frame_sync.command_pool, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(vk.CommandBuffer(cmd), &begin_info))
}

cmd_end_recording :: proc(cmd: CommandBuffer) {
	vk_check(vk.EndCommandBuffer(vk.CommandBuffer(cmd)))
}

cmd_set_depth_bias :: proc(cmd: CommandBuffer, bias, clamp, slope: f32) {
	vk.CmdSetDepthBias(vk.CommandBuffer(cmd), bias, clamp, slope)
}

cmd_draw :: proc(
	cmd: CommandBuffer,
	vertex_count: u32 = 3,
	instance_count: u32 = 1,
	first_vertex: u32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDraw(vk.CommandBuffer(cmd), vertex_count, instance_count, first_vertex, first_instance)
}

cmd_draw_indexed :: proc(cmd: CommandBuffer, index_buffer: vk.Buffer, index_count: u32) {
	vk.CmdBindIndexBuffer(vk.CommandBuffer(cmd), index_buffer, 0, .UINT32)
	vk.CmdDrawIndexed(vk.CommandBuffer(cmd), index_count, 1, 0, 0, 0)
}

cmd_dispatch :: proc(cmd: CommandBuffer, x, y, z: u32) {
	vk.CmdDispatch(vk.CommandBuffer(cmd), x, y, z)
}

cmd_pipeline_barrier_memory :: proc(
	cmd: CommandBuffer,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = src_stage,
		srcAccessMask = src_access,
		dstStageMask  = dst_stage,
		dstAccessMask = dst_access,
	}
	dep_info := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(vk.CommandBuffer(cmd), &dep_info)
}

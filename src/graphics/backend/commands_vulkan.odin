#+build linux

package backend

import vk "vendor:vulkan"

begin_immediate_submit :: proc(ctx: ^Context) -> vk.CommandBuffer {
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

end_immediate_submit :: proc(ctx: ^Context, cmd: CommandBuffer) {
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
immediate_submit :: proc(ctx: ^Context) -> (cmd: CommandBuffer) {
	return CommandBuffer(begin_immediate_submit(ctx))
}

cmd_begin_recording :: proc(ctx: ^Context, cmd: CommandBuffer, frame_index: u64) {
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

	cmd_use_buffer :: proc(cmd: RenderEncoder, buffer: GpuBuffer($T)) {
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

cmd_draw_points :: proc(cmd: RenderEncoder, vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0) {
	vk.CmdDraw(vk.CommandBuffer(cmd), vertex_count, instance_count, first_vertex, 0)
}

cmd_draw_indexed :: proc(cmd: CommandBuffer, index_buffer: vk.Buffer, index_count: u32) {
	vk.CmdBindIndexBuffer(vk.CommandBuffer(cmd), index_buffer, 0, .UINT32)
	vk.CmdDrawIndexed(vk.CommandBuffer(cmd), index_count, 1, 0, 0, 0)
}

cmd_dispatch :: proc(cmd: CommandBuffer, x, y, z: u32) {
	vk.CmdDispatch(vk.CommandBuffer(cmd), x, y, z)
}

cmd_barrier_compute_write_to_vertex_read :: proc(cmd: ComputeEncoder) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.VERTEX_SHADER},
		dstAccessMask = {.SHADER_READ},
	}
	dep_info := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(vk.CommandBuffer(cmd), &dep_info)
}

pipeline_bind_compute :: proc(cmd: ComputeEncoder, pipeline: Pipeline) {
	vk.CmdBindPipeline(vk.CommandBuffer(cmd), .COMPUTE, pipeline.pipeline)
}

pipeline_push_compute :: proc(cmd: ComputeEncoder, pipeline: Pipeline, data: ^$T, offset: u32 = 0) {
	vk.CmdPushConstants(vk.CommandBuffer(cmd), pipeline.layout, {.COMPUTE}, offset, u32(size_of(T)), data)
}

begin_compute_pass :: proc(ctx: ^Context, cmd: CommandBuffer) -> ComputeEncoder {
	return ComputeEncoder(cmd)
}

end_compute_pass :: proc(encoder: ComputeEncoder) {
}

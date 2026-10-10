package backend

import vk "vendor:vulkan"

@(private)
begin_immediate_submit :: proc(ctx: ^Context) -> CommandBuffer {
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
	return CommandBuffer{handle = cmd, ctx = ctx}
}

@(private)
end_immediate_submit :: proc(ctx: ^Context, cmd: CommandBuffer) {
	cmd := cmd.handle
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
	return begin_immediate_submit(ctx)
}

cmd_begin_recording :: proc(ctx: ^Context, cmd: CommandBuffer) {
	frame_sync := current_frame_sync(ctx)
	vk.ResetCommandPool(ctx.device, frame_sync.command_pool, {})

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd.handle, &begin_info))
}

cmd_end_recording :: proc(cmd: CommandBuffer) {
	vk_check(vk.EndCommandBuffer(cmd.handle))
}

cmd_set_depth_bias :: proc(cmd: RenderEncoder, bias, clamp, slope: f32) {
	vk.CmdSetDepthBias(cmd.handle, bias, clamp, slope)
}

cmd_draw :: proc(
	cmd: RenderEncoder,
	vertex_count: u32 = 3,
	instance_count: u32 = 1,
	first_vertex: u32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDraw(cmd.handle, vertex_count, instance_count, first_vertex, first_instance)
}

cmd_draw_points :: proc(cmd: RenderEncoder, vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0) {
	vk.CmdDraw(cmd.handle, vertex_count, instance_count, first_vertex, 0)
}

// firstInstance is always 0: pass any instance offset yourself (see instancing.odin).
cmd_draw_indexed :: proc(cmd: RenderEncoder, index_buffer: Buffer(u32), index_count: u32, instance_count: u32 = 1) {
	vk.CmdBindIndexBuffer(cmd.handle, buffer_slot(cmd.ctx, index_buffer).buffer, 0, .UINT32)
	vk.CmdDrawIndexed(cmd.handle, index_count, instance_count, 0, 0, 0)
}

// Vulkan takes the local workgroup size from the shader.
cmd_dispatch :: proc(cmd: ComputeEncoder, x, y, z: u32, threads_per_group: [3]u32) {
	vk.CmdDispatch(cmd.handle, x, y, z)
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
	vk.CmdPipelineBarrier2(cmd.handle, &dep_info)
}

cmd_barrier_compute_write_to_compute_read :: proc(cmd: ComputeEncoder) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.COMPUTE_SHADER},
		dstAccessMask = {.SHADER_READ},
	}
	dep_info := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd.handle, &dep_info)
}

// Binds the pipeline and the bindless table (set 0).
pipeline_bind_compute :: proc(cmd: ComputeEncoder, pipeline: Pipeline) {
	vk.CmdBindPipeline(cmd.handle, .COMPUTE, pipeline.pipeline)
	vk.CmdBindDescriptorSets(
		cmd.handle,
		.COMPUTE,
		cmd.ctx.bindless.pipeline_layout,
		0,
		1,
		&cmd.ctx.bindless.set,
		0,
		nil,
	)
}

pipeline_push_compute :: proc(cmd: ComputeEncoder, data: ^$T) {
	#assert(size_of(T) <= PUSH_CONSTANT_SIZE)
	vk.CmdPushConstants(cmd.handle, cmd.ctx.bindless.pipeline_layout, PUSH_CONSTANT_STAGES, 0, u32(size_of(T)), data)
}

begin_compute_pass :: proc(ctx: ^Context, cmd: CommandBuffer) -> ComputeEncoder {
	return ComputeEncoder(cmd)
}

end_compute_pass :: proc(encoder: ComputeEncoder) {
}

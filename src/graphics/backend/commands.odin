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

cmd_begin_recording :: proc(cmd: CommandBuffer) {
	frame_sync := current_frame_sync(cmd.ctx)
	vk.ResetCommandPool(cmd.ctx.device, frame_sync.command_pool, {})

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

cmd_bind_index_buffer :: proc(cmd: RenderEncoder, index_buffer: Buffer(u32)) {
	vk.CmdBindIndexBuffer(cmd.handle, buffer_slot(cmd.ctx, index_buffer).buffer, 0, .UINT32)
}

// first_instance offsets SV_StartInstanceLocation; shaders add it to SV_InstanceID (see instancing.odin).
cmd_draw_indexed :: proc(
	cmd: RenderEncoder,
	index_count: u32,
	instance_count: u32 = 1,
	first_index: u32 = 0,
	vertex_offset: i32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDrawIndexed(cmd.handle, index_count, instance_count, first_index, vertex_offset, first_instance)
}

cmd_draw_indexed_indirect :: proc(cmd: RenderEncoder, buffer: Buffer($T), offset: u64, draw_count, stride: u32) {
	assert(draw_count <= cmd.ctx.max_draw_indirect_count, "cmd_draw_indexed_indirect: draw count exceeds device limit")
	assert(stride >= size_of(T) && stride % 4 == 0, "cmd_draw_indexed_indirect: invalid stride")
	assert(.Indirect in buffer_desc(cmd.ctx, buffer).usage, "cmd_draw_indexed_indirect: buffer lacks indirect usage")
	vk.CmdDrawIndexedIndirect(
		cmd.handle,
		buffer_slot(cmd.ctx, buffer).buffer,
		vk.DeviceSize(offset),
		draw_count,
		stride,
	)
}

cmd_dispatch :: proc(cmd: ComputeEncoder, x, y, z: u32) {
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

// Host reads of a buffer the GPU just wrote. The queue wait only orders device work, so this barrier is
// what makes the writes visible to the CPU.
cmd_barrier_transfer_write_to_host_read :: proc(cmd: CommandBuffer, buf: Buffer($T)) {
	barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {.COPY},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask  = {.HOST},
		dstAccessMask = {.HOST_READ},
		buffer        = buffer_slot(cmd.ctx, buf).buffer,
		size          = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	dep_info := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &barrier,
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

begin_compute_pass :: proc(cmd: CommandBuffer) -> ComputeEncoder {
	return ComputeEncoder(cmd)
}

end_compute_pass :: proc(encoder: ComputeEncoder) {
}

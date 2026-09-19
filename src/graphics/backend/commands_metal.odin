#+build darwin

package backend

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

cmd_begin_recording :: proc(ctx: ^Context, cmd: CommandBuffer, frame_index: u64) {
}

cmd_end_recording :: proc(cmd: CommandBuffer) {
}

// The pool spans begin..end so the caller's encoders land in it too. Stashed on the
// context because the deferred call only gets (ctx, cmd); immediate submits never nest.
@(deferred_in_out = end_immediate_submit)
immediate_submit :: proc(ctx: ^Context) -> CommandBuffer {
	ctx.immediate_pool = autorelease_pool_begin()
	return CommandBuffer(ctx.command_queue->commandBuffer())
}

end_immediate_submit :: proc(ctx: ^Context, cmd: CommandBuffer) {
	mtl_cmd := (^MTL.CommandBuffer)(cmd)
	mtl_cmd->commit()
	mtl_cmd->waitUntilCompleted()
	autorelease_pool_end(ctx.immediate_pool)
	ctx.immediate_pool = nil
}

cmd_draw :: proc(cmd: RenderEncoder, vertex_count: u32 = 3, instance_count: u32 = 1, first_vertex: u32 = 0) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	encoder->drawPrimitivesWithInstanceCount(
		.Triangle,
		NS.UInteger(first_vertex),
		NS.UInteger(vertex_count),
		NS.UInteger(instance_count),
	)
}

cmd_draw_points :: proc(cmd: RenderEncoder, vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	encoder->drawPrimitivesWithInstanceCount(
		.Point,
		NS.UInteger(first_vertex),
		NS.UInteger(vertex_count),
		NS.UInteger(instance_count),
	)
}

cmd_draw_indexed :: proc(cmd: RenderEncoder, index_buffer: ^MTL.Buffer, index_count: u32) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	encoder->drawIndexedPrimitives(.Triangle, NS.UInteger(index_count), .UInt32, index_buffer, 0)
}

cmd_dispatch :: proc(cmd: ComputeEncoder, x, y, z: u32) {
	encoder := (^MTL.ComputeCommandEncoder)(cmd)
	encoder->dispatchThreadgroups(MTL.Size{NS.Integer(x), NS.Integer(y), NS.Integer(z)}, MTL.Size{1, 1, 1})
}

	cmd_set_depth_bias :: proc(cmd: RenderEncoder, bias, clamp, slope: f32) {
		encoder := (^MTL.RenderCommandEncoder)(cmd)
		encoder->setDepthBias(bias, slope, clamp)
	}

	cmd_use_buffer :: proc(cmd: RenderEncoder, buffer: GpuBuffer($T)) {
		encoder := (^MTL.RenderCommandEncoder)(cmd)
		encoder->useResourceWithStages((^MTL.Resource)(buffer.buffer), {.Read}, {.Vertex, .Fragment})
	}

cmd_barrier_compute_write_to_vertex_read :: proc(cmd: ComputeEncoder) {
}

pipeline_bind_compute :: proc(cmd: ComputeEncoder, pipeline: Pipeline) {
	encoder := (^MTL.ComputeCommandEncoder)(cmd)
	encoder->setComputePipelineState(pipeline.compute_state)
}

pipeline_push_compute :: proc(cmd: ComputeEncoder, pipeline: Pipeline, data: ^$T, offset: u32 = 0) {
	encoder := (^MTL.ComputeCommandEncoder)(cmd)
	bytes := (cast([^]byte)data)[:size_of(T)]
	encoder->setBytes(bytes, NS.UInteger(offset))
}

begin_compute_pass :: proc(ctx: ^Context, cmd: CommandBuffer) -> ComputeEncoder {
	cmd_buffer := (^MTL.CommandBuffer)(cmd)
	return ComputeEncoder(cmd_buffer->computeCommandEncoder())
}

end_compute_pass :: proc(encoder: ComputeEncoder) {
	(^MTL.ComputeCommandEncoder)(encoder)->endEncoding()
}

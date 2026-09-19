#+build darwin

package backend

import "core:mem"

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

GpuBuffer :: struct($T: typeid) {
	buffer: ^MTL.Buffer,
	ptr:    GPUPtr(T),
}

GPUPtr :: struct($T: typeid) {
	address: u64,
}

BufferFlags :: struct {
	options: MTL.ResourceOptions,
}

BufferKind :: enum {
	Storage,
	MappedUniform,
	MappedStorage,
	Index,
	Staging,
	ParticleSSBO,
}

BUFFER_FLAGS := [BufferKind]BufferFlags {
	.Storage       = {{}},
	.MappedUniform = {{}},
	.MappedStorage = {{}},
	.Index         = {{}},
	.Staging       = {{}},
	.ParticleSSBO  = {{}},
}

buffer_create :: proc($T: typeid, ctx: ^Context, count: int, kind: BufferKind) -> GpuBuffer(T) {
	buffer_flags := BUFFER_FLAGS[kind]
	size := NS.UInteger(size_of(T) * count)

	gpu_buf: GpuBuffer(T)
	gpu_buf.buffer = ctx.device->newBufferWithLength(size, buffer_flags.options)
	gpu_buf.ptr.address = gpu_buf.buffer->gpuAddress()

	return gpu_buf
}

buffer_destroy :: proc(ctx: ^Context, buffer: GpuBuffer($T)) {
	buffer.buffer->release()
}

buffer_mapped_ptr :: proc(buffer: GpuBuffer($T)) -> rawptr {
	return raw_data(buffer.buffer->contents())
}

buffer_upload :: proc(ctx: ^Context, data: []$T, kind: BufferKind) -> GpuBuffer(T) {
	dest := buffer_create(T, ctx, len(data), kind)
	contents := dest.buffer->contents()
	copy(contents, mem.slice_to_bytes(data))
	return dest
}

buffer_copy :: proc(ctx: ^Context, src, dst: ^MTL.Buffer, size: int) {
	cmd_buffer := ctx.command_queue->commandBuffer()
	encoder := cmd_buffer->blitCommandEncoder()
	encoder->copyFromBuffer(src, 0, dst, 0, NS.UInteger(size))
	encoder->endEncoding()
	cmd_buffer->commit()
}

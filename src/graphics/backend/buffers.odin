package backend

import "core:mem"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

GpuBuffer :: struct($T: typeid) {
	buffer:     vk.Buffer,
	alloc:      vma.Allocation,
	alloc_info: vma.Allocation_Info,
	ptr:        GPUPtr(T),
}

GPUPtr :: struct($T: typeid) {
	address: vk.DeviceAddress,
}

BufferFlags :: struct {
	usage: vk.BufferUsageFlags,
	alloc: vma.Allocation_Create_Flags,
}

BufferKind :: enum {
	Storage,
	MappedUniform,
	MappedStorage,
	Index,
	Staging,
	Readback,
	ParticleSSBO,
}

BUFFER_FLAGS := [BufferKind]BufferFlags {
	.Storage       = {{.TRANSFER_DST, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, {}},
	.MappedUniform = {{.TRANSFER_DST, .UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS}, {.Mapped, .Host_Access_Random}},
	.MappedStorage = {{.TRANSFER_DST, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, {.Mapped, .Host_Access_Random}},
	.Index         = {{.TRANSFER_DST, .INDEX_BUFFER}, {}},
	.Staging       = {{.TRANSFER_SRC}, {.Mapped, .Host_Access_Sequential_Write}},
	.Readback      = {{.TRANSFER_DST}, {.Mapped, .Host_Access_Random}},
	.ParticleSSBO  = {{.TRANSFER_DST, .STORAGE_BUFFER, .VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS}, {}},
}

buffer_create :: proc($T: typeid, ctx: ^Context, count: int, kind: BufferKind) -> GpuBuffer(T) {
	buffer_flags := BUFFER_FLAGS[kind]
	size := vk.DeviceSize(size_of(T) * count)

	gpu_buf: GpuBuffer(T)
	vk_check(
		vma.create_buffer(
			ctx.vma_allocator,
			vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = size, usage = buffer_flags.usage},
			vma.Allocation_Create_Info{usage = .Auto, flags = buffer_flags.alloc},
			&gpu_buf.buffer,
			&gpu_buf.alloc,
			&gpu_buf.alloc_info,
		),
	)

	if .SHADER_DEVICE_ADDRESS in buffer_flags.usage {
		addr_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = gpu_buf.buffer,
		}
		gpu_buf.ptr.address = vk.GetBufferDeviceAddress(ctx.device, &addr_info)
	}

	return gpu_buf
}

buffer_destroy :: proc(ctx: ^Context, buffer: GpuBuffer($T)) {
	vma.destroy_buffer(ctx.vma_allocator, buffer.buffer, buffer.alloc)
}

buffer_mapped_ptr :: proc(buffer: GpuBuffer($T)) -> rawptr {
	return buffer.alloc_info.mapped_data
}

buffer_upload :: proc(ctx: ^Context, data: []$T, kind: BufferKind) -> GpuBuffer(T) {
	size := vk.DeviceSize(size_of(T) * len(data))

	staging := buffer_create(T, ctx, len(data), .Staging)
	defer buffer_destroy(ctx, staging)

	mem.copy(staging.alloc_info.mapped_data, raw_data(data), int(size))

	dest := buffer_create(T, ctx, len(data), kind)
	buffer_copy(ctx, staging.buffer, dest.buffer, size)
	return dest
}

buffer_copy :: proc(ctx: ^Context, src, dst: vk.Buffer, size: vk.DeviceSize) {
	cmd := immediate_submit(ctx)
	region := vk.BufferCopy {
		size = size,
	}
	vk.CmdCopyBuffer(vk.CommandBuffer(cmd), src, dst, 1, &region)
}

package backend

import "core:mem"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

import "../../handles"

// Handle to a backend-owned buffer of T. T only tags the handle at compile time, so a
// Buffer(Vertex) can't be passed where a Buffer(GpuMaterial) is expected. The zero value
// means "no buffer".
Buffer :: struct($T: typeid) {
	handle: handles.Handle(BufferSlot),
}

// Typed GPU address of a buffer, for push constants (buffer device address).
GPUPtr :: struct($T: typeid) {
	address: vk.DeviceAddress,
}

MAX_BUFFERS :: 8192

// What the GPU does with the buffer.
BufferUsage :: enum {
	Storage,
	Uniform,
	Vertex,
	Index,
	Transfer_Src,
	Transfer_Dst,
}

BufferUsageFlags :: bit_set[BufferUsage]

// Where the memory lives and how the CPU reaches it.
BufferMemory :: enum {
	Gpu, // device-local, no CPU access
	Upload, // CPU writes once, GPU reads (staging)
	Shared, // CPU writes every frame, GPU reads; stays mapped
	Readback, // GPU writes, CPU reads
}

BufferDesc :: struct {
	size:   int, // bytes
	usage:  BufferUsageFlags,
	memory: BufferMemory,
}

@(private)
BufferSlot :: struct {
	desc:    BufferDesc,
	buffer:  vk.Buffer,
	alloc:   vma.Allocation,
	mapped:  rawptr, // nil for .Gpu memory
	address: vk.DeviceAddress, // 0 unless the usage needs a device address
}

// Buffers the shaders reach through a device address (BDA in push constants).
@(private = "file")
ADDRESS_USAGE :: BufferUsageFlags{.Storage, .Uniform, .Vertex}

@(private = "file")
buffer_usage_to_vk :: proc(usage: BufferUsageFlags) -> vk.BufferUsageFlags {
	flags: vk.BufferUsageFlags
	if .Storage in usage do flags += {.STORAGE_BUFFER}
	if .Uniform in usage do flags += {.UNIFORM_BUFFER}
	if .Vertex in usage do flags += {.VERTEX_BUFFER}
	if .Index in usage do flags += {.INDEX_BUFFER}
	if .Transfer_Src in usage do flags += {.TRANSFER_SRC}
	if .Transfer_Dst in usage do flags += {.TRANSFER_DST}
	if usage & ADDRESS_USAGE != {} do flags += {.SHADER_DEVICE_ADDRESS}
	return flags
}

@(private = "file")
buffer_memory_to_vma :: proc(memory: BufferMemory) -> vma.Allocation_Create_Flags {
	switch memory {
	case .Gpu:
		return {}
	case .Upload:
		return {.Mapped, .Host_Access_Sequential_Write}
	case .Shared, .Readback:
		return {.Mapped, .Host_Access_Random}
	}
	return {}
}

buffers_init :: proc(ctx: ^Context) {
	ctx.buffers = handles.pool_init(MAX_BUFFERS, BufferSlot)
}

buffers_destroy :: proc(ctx: ^Context) {
	handles.pool_destroy(&ctx.buffers)
}

@(private)
buffer_slot :: proc(ctx: ^Context, buf: Buffer($T)) -> ^BufferSlot {
	return handles.pool_get(&ctx.buffers, buf.handle)
}

buffer_is_valid :: proc(buf: Buffer($T)) -> bool {
	return buf.handle.generation != 0
}

buffer_create :: proc(
	$T: typeid,
	ctx: ^Context,
	count: int,
	usage: BufferUsageFlags,
	memory: BufferMemory,
) -> Buffer(T) {
	desc := BufferDesc {
		size   = size_of(T) * count,
		usage  = usage,
		memory = memory,
	}
	slot := BufferSlot {
		desc = desc,
	}
	alloc_info: vma.Allocation_Info
	vk_check(
		vma.create_buffer(
			ctx.vma_allocator,
			vk.BufferCreateInfo {
				sType = .BUFFER_CREATE_INFO,
				size = vk.DeviceSize(desc.size),
				usage = buffer_usage_to_vk(usage),
			},
			vma.Allocation_Create_Info{usage = .Auto, flags = buffer_memory_to_vma(memory)},
			&slot.buffer,
			&slot.alloc,
			&alloc_info,
		),
	)
	slot.mapped = alloc_info.mapped_data

	if usage & ADDRESS_USAGE != {} {
		addr_info := vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = slot.buffer,
		}
		slot.address = vk.GetBufferDeviceAddress(ctx.device, &addr_info)
	}

	return Buffer(T){handle = handles.pool_alloc(&ctx.buffers, slot)}
}

buffer_destroy :: proc(ctx: ^Context, buf: Buffer($T)) {
	slot := buffer_slot(ctx, buf)
	vma.destroy_buffer(ctx.vma_allocator, slot.buffer, slot.alloc)
	handles.pool_free(&ctx.buffers, buf.handle)
}

buffer_desc :: proc(ctx: ^Context, buf: Buffer($T)) -> BufferDesc {
	return buffer_slot(ctx, buf).desc
}

// Typed GPU address for push constants. Asserts the buffer was created with an address usage.
buffer_address :: proc(ctx: ^Context, buf: Buffer($T)) -> GPUPtr(T) {
	slot := buffer_slot(ctx, buf)
	assert(slot.address != 0, "buffer_address: buffer has no Storage/Uniform/Vertex usage")
	return {address = slot.address}
}

// CPU pointer to the buffer's memory, like Metal's contents(). Only mapped memory
// (.Upload, .Shared, .Readback) has one. The caller keeps writes in bounds and off memory
// an in-flight frame is still reading.
buffer_contents :: proc(ctx: ^Context, buf: Buffer($T)) -> rawptr {
	slot := buffer_slot(ctx, buf)
	assert(slot.mapped != nil, "buffer_contents: buffer memory is not mapped")
	return slot.mapped
}

// Creates a .Gpu buffer with the given usage (plus Transfer_Dst) and copies data into it
// through a staging buffer.
buffer_upload :: proc(ctx: ^Context, data: []$T, usage: BufferUsageFlags) -> Buffer(T) {
	staging := buffer_create(T, ctx, len(data), {.Transfer_Src}, .Upload)
	defer buffer_destroy(ctx, staging)
	mem.copy(buffer_contents(ctx, staging), raw_data(data), size_of(T) * len(data))

	dest := buffer_create(T, ctx, len(data), usage + {.Transfer_Dst}, .Gpu)
	cmd := immediate_submit(ctx)
	region := vk.BufferCopy {
		size = vk.DeviceSize(size_of(T) * len(data)),
	}
	vk.CmdCopyBuffer(cmd.handle, buffer_slot(ctx, staging).buffer, buffer_slot(ctx, dest).buffer, 1, &region)
	return dest
}

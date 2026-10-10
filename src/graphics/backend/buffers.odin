package backend

import "base:runtime"
import "core:fmt"

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

MAX_BUFFERS :: 32768

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
	assert(handles.pool_live_count(&ctx.buffers) == 0, "buffers_destroy: buffers still alive")
	handles.pool_destroy(&ctx.buffers)
}

@(private)
buffer_slot :: proc(ctx: ^Context, buf: Buffer($T)) -> ^BufferSlot {
	return handles.pool_get(&ctx.buffers, buf.handle)
}

// True while the buffer is alive: false for the zero handle and after buffer_destroy.
buffer_is_valid :: proc(ctx: ^Context, buf: Buffer($T)) -> bool {
	return handles.pool_is_valid(&ctx.buffers, buf.handle)
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

// Frees the handle now; the Vulkan buffer is released once in-flight frames are done with it.
buffer_destroy :: proc(ctx: ^Context, buf: Buffer($T)) {
	release_deferred(ctx, buffer_slot(ctx, buf)^)
	handles.pool_free(&ctx.buffers, buf.handle)
}

@(private)
buffer_slot_release :: proc(ctx: ^Context, slot: BufferSlot) {
	vma.destroy_buffer(ctx.vma_allocator, slot.buffer, slot.alloc)
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

// Element range [first, first+count) of a mapped buffer as a CPU slice. Asserts the buffer is mapped
// and the range fits. The message names the caller's file and line.
@(private = "file")
buffer_mapped_range :: proc(
	ctx: ^Context,
	buf: Buffer($T),
	first, count: int,
	op: string,
	loc: runtime.Source_Code_Location,
) -> []T {
	slot := buffer_slot(ctx, buf)
	fmt.assertf(slot.mapped != nil, "%s: buffer memory is not mapped", op, loc = loc)
	capacity := slot.desc.size / size_of(T)
	fmt.assertf(
		first >= 0 && count >= 0 && first + count <= capacity,
		"%s: elements [%d, %d+%d) out of range for a %d-element buffer",
		op,
		first,
		first,
		count,
		capacity,
		loc = loc,
	)
	return ([^]T)(slot.mapped)[first:][:count]
}

// Maps elements [first, first+count) for CPU writes. The flush runs when the calling scope ends, so
// the writes must happen inside that scope. Mapped buffers only. The caller keeps writes in bounds and
// off memory an in-flight frame is still reading.
@(deferred_in_out = buffer_map_commit)
buffer_map_write :: proc(ctx: ^Context, buf: Buffer($T), first, count: int, loc := #caller_location) -> []T {
	return buffer_mapped_range(ctx, buf, first, count, "buffer_map_write", loc)
}

// Flushes the range written through buffer_map_write. A no-op on HOST_COHERENT memory.
@(private)
buffer_map_commit :: proc(ctx: ^Context, buf: Buffer($T), first, count: int, loc := #caller_location, _: []T) {
	slot := buffer_slot(ctx, buf)
	vk_check(
		vma.flush_allocation(
			ctx.vma_allocator,
			slot.alloc,
			vk.DeviceSize(first * size_of(T)),
			vk.DeviceSize(count * size_of(T)),
		),
		"buffer_map_commit: flush failed",
		loc,
	)
}

// Writes data (or one value) into the buffer at element first (or index). Works for any mapped memory.
// The caller keeps writes in bounds and off memory an in-flight frame is still reading.
buffer_write :: proc {
	buffer_write_slice,
	buffer_write_value,
}

buffer_write_slice :: proc(ctx: ^Context, buf: Buffer($T), data: []T, first := 0, loc := #caller_location) {
	dst := buffer_map_write(ctx, buf, first, len(data), loc)
	copy(dst, data)
}

buffer_write_value :: proc(ctx: ^Context, buf: Buffer($T), value: T, index := 0, loc := #caller_location) {
	dst := buffer_map_write(ctx, buf, index, 1, loc)
	dst[0] = value
}

// Copies elements [first, first+len(out)) out of mapped memory. Invalidates the range first, so
// non-coherent readback memory is current. Call it after the GPU work that wrote the data has completed.
buffer_read :: proc(ctx: ^Context, buf: Buffer($T), out: []T, first := 0, loc := #caller_location) {
	src := buffer_mapped_range(ctx, buf, first, len(out), "buffer_read", loc)
	vk_check(
		vma.invalidate_allocation(
			ctx.vma_allocator,
			buffer_slot(ctx, buf).alloc,
			vk.DeviceSize(first * size_of(T)),
			vk.DeviceSize(len(out) * size_of(T)),
		),
		"buffer_read: invalidate failed",
		loc,
	)
	copy(out, src)
}

// Creates a .Gpu buffer with the given usage (plus Transfer_Dst) and copies data into it
// through a staging buffer.
buffer_upload :: proc(ctx: ^Context, data: []$T, usage: BufferUsageFlags) -> Buffer(T) {
	staging := buffer_create(T, ctx, len(data), {.Transfer_Src}, .Upload)
	defer buffer_destroy(ctx, staging)
	buffer_write(ctx, staging, data)

	dest := buffer_create(T, ctx, len(data), usage + {.Transfer_Dst}, .Gpu)
	cmd := immediate_submit(ctx)
	region := vk.BufferCopy {
		size = vk.DeviceSize(size_of(T) * len(data)),
	}
	vk.CmdCopyBuffer(cmd.handle, buffer_slot(ctx, staging).buffer, buffer_slot(ctx, dest).buffer, 1, &region)
	return dest
}

// Copies data into an existing device-local buffer at element offset first.
buffer_upload_range :: proc(ctx: ^Context, buf: Buffer($T), data: []T, first: int, loc := #caller_location) {
	dest_slot := buffer_slot(ctx, buf)
	capacity := dest_slot.desc.size / size_of(T)
	fmt.assertf(
		first >= 0 && first + len(data) <= capacity,
		"buffer_upload_range: elements [%d, %d+%d) out of range for a %d-element buffer",
		first,
		first,
		len(data),
		capacity,
		loc = loc,
	)
	staging := buffer_create(T, ctx, len(data), {.Transfer_Src}, .Upload)
	defer buffer_destroy(ctx, staging)
	buffer_write(ctx, staging, data)

	cmd := immediate_submit(ctx)
	region := vk.BufferCopy {
		srcOffset = 0,
		dstOffset = vk.DeviceSize(first * size_of(T)),
		size      = vk.DeviceSize(len(data) * size_of(T)),
	}
	vk.CmdCopyBuffer(cmd.handle, buffer_slot(ctx, staging).buffer, dest_slot.buffer, 1, &region)
}

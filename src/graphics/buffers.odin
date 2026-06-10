package graphics

import "core:mem"
import "core:time"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

copy_buffer :: proc(engine: ^Engine, src, dst: vk.Buffer, size: vk.DeviceSize) {
	cmd := begin_single_time_commands(engine)
	region := vk.BufferCopy {
		size = size,
	}
	vk.CmdCopyBuffer(cmd, src, dst, 1, &region)
	end_single_time_commands(engine, &cmd)
}

create_uniform_buffers :: proc(engine: ^Engine) {
	buffer_size := vk.DeviceSize(size_of(UniformBufferObject))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk_check(
			vma.create_buffer(
				engine.vma_allocator,
				vk.BufferCreateInfo {
					sType = .BUFFER_CREATE_INFO,
					size = buffer_size,
					usage = {.UNIFORM_BUFFER},
					sharingMode = .EXCLUSIVE,
				},
				vma.Allocation_Create_Info {
					usage = .Auto,
					flags = {.Host_Access_Sequential_Write, .Host_Access_Allow_Transfer_Instead, .Mapped},
				},
				&engine.uniform_buffers[i],
				&engine.uniform_buffer_allocations[i],
				nil,
			),
		)

		alloc_info: vma.Allocation_Info
		vma.get_allocation_info(engine.vma_allocator, engine.uniform_buffer_allocations[i], &alloc_info)
		engine.uniform_buffers_mapped[i] = alloc_info.mapped_data
	}
}

update_uniform_buffer :: proc(engine: ^Engine, frame_index: u64) {
	current_time := time.now()

	duration := time.diff(engine.start_time, current_time)
	t := f32(time.duration_seconds(duration))

	ubo := UniformBufferObject{}

	ubo.view = camera_get_view_matrix(engine.camera)
	ubo.proj = camera_get_projection_matrix(engine.camera, f32(engine.swapchain_width) / f32(engine.swapchain_height))

	// vulkans y coordinate is flipped
	ubo.proj[1][1] *= -1.0

	ubo.light_pos = {2.0, 4.0, 3.0, 0.0}

	mem.copy(engine.uniform_buffers_mapped[frame_index], &ubo, size_of(UniformBufferObject))
}

create_geometry_buffer :: proc(engine: ^Engine) {
	vertex_count: int
	index_count: int

	for &mesh in engine.meshes {
		mesh.vertex_offset = u32(vertex_count)
		mesh.index_offset = u32(index_count)
		vertex_count += len(mesh.vertices)
		index_count += len(mesh.indices)
	}

	vertex_size := vk.DeviceSize(size_of(Vertex) * vertex_count)
	index_size := vk.DeviceSize(size_of(u32) * index_count)
	total_size := vertex_size + index_size

	engine.index_buffer_offset = vertex_size

	staging_buffer: vk.Buffer
	staging_allocation: vma.Allocation
	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
			vk.BufferCreateInfo {
				sType = .BUFFER_CREATE_INFO,
				size = total_size,
				usage = {.TRANSFER_SRC},
				sharingMode = .EXCLUSIVE,
			},
			vma.Allocation_Create_Info{usage = .Auto, flags = {.Host_Access_Sequential_Write}},
			&staging_buffer,
			&staging_allocation,
			nil,
		),
	)
	defer vma.destroy_buffer(engine.vma_allocator, staging_buffer, staging_allocation)

	data: rawptr
	vk_check(vma.map_memory(engine.vma_allocator, staging_allocation, &data))
	v_dst := uintptr(data)
	i_dst := uintptr(data) + uintptr(vertex_size)
	for mesh in engine.meshes {
		v_bytes := size_of(Vertex) * len(mesh.vertices)
		i_bytes := size_of(u32) * len(mesh.indices)
		mem.copy(rawptr(v_dst), raw_data(mesh.vertices), v_bytes)
		mem.copy(rawptr(i_dst), raw_data(mesh.indices), i_bytes)
		v_dst += uintptr(v_bytes)
		i_dst += uintptr(i_bytes)
	}
	vma.unmap_memory(engine.vma_allocator, staging_allocation)

	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
			vk.BufferCreateInfo {
				sType = .BUFFER_CREATE_INFO,
				size = total_size,
				usage = {.TRANSFER_DST, .VERTEX_BUFFER, .INDEX_BUFFER, .SHADER_DEVICE_ADDRESS},
				sharingMode = .EXCLUSIVE,
			},
			vma.Allocation_Create_Info{usage = .Auto, required_flags = {.DEVICE_LOCAL}},
			&engine.geometry_buffer,
			&engine.geometry_buffer_allocation,
			nil,
		),
	)

	copy_buffer(engine, staging_buffer, engine.geometry_buffer, total_size)

	addr_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = engine.geometry_buffer,
	}
	engine.geometry_buffer_address = vk.GetBufferDeviceAddress(engine.device, &addr_info)
}

create_material_buffer :: proc(engine: ^Engine) {
	if len(engine.materials) == 0 do return
	total_size := vk.DeviceSize(size_of(Material) * len(engine.materials))

	staging_buffer: vk.Buffer
	staging_allocation: vma.Allocation
	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
			vk.BufferCreateInfo {
				sType = .BUFFER_CREATE_INFO,
				size = total_size,
				usage = {.TRANSFER_SRC},
				sharingMode = .EXCLUSIVE,
			},
			vma.Allocation_Create_Info{usage = .Auto, flags = {.Host_Access_Sequential_Write}},
			&staging_buffer,
			&staging_allocation,
			nil,
		),
	)
	defer vma.destroy_buffer(engine.vma_allocator, staging_buffer, staging_allocation)

	data: rawptr
	vk_check(vma.map_memory(engine.vma_allocator, staging_allocation, &data))
	mem.copy(data, raw_data(engine.materials[:]), int(total_size))
	vma.unmap_memory(engine.vma_allocator, staging_allocation)

	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
			vk.BufferCreateInfo {
				sType = .BUFFER_CREATE_INFO,
				size = total_size,
				usage = {.TRANSFER_DST, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
				sharingMode = .EXCLUSIVE,
			},
			vma.Allocation_Create_Info{usage = .Auto, required_flags = {.DEVICE_LOCAL}},
			&engine.material_buffer,
			&engine.material_buffer_allocation,
			nil,
		),
	)

	copy_buffer(engine, staging_buffer, engine.material_buffer, total_size)

	addr_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = engine.material_buffer,
	}
	engine.material_buffer_address = vk.GetBufferDeviceAddress(engine.device, &addr_info)
}


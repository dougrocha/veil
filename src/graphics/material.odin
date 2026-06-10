package graphics

import "core:mem"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

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


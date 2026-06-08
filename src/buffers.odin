package main

import "core:math/linalg"
import "core:mem"
import "core:time"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

copy_buffer :: proc(engine: ^Engine, src, dst: vk.Buffer, size: vk.DeviceSize) {
	cmd_alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = engine.frame_resources[0].command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	cmd: vk.CommandBuffer
	vk_check(vk.AllocateCommandBuffers(engine.device, &cmd_alloc_info, &cmd))
	defer vk.FreeCommandBuffers(engine.device, engine.frame_resources[0].command_pool, 1, &cmd)

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	region := vk.BufferCopy {
		size = size,
	}
	vk.CmdCopyBuffer(cmd, src, dst, 1, &region)

	vk_check(vk.EndCommandBuffer(cmd))

	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}
	vk_check(vk.QueueSubmit(engine.graphics_queue, 1, &submit_info, 0))
	vk_check(vk.QueueWaitIdle(engine.graphics_queue))
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
				vma.Allocation_Create_Info{usage = .Auto, flags = {.Host_Access_Sequential_Write, .Mapped}},
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
	time := f32(time.duration_seconds(duration))

	ubo := UniformBufferObject{}
	ubo.model = linalg.matrix4_rotate(time * linalg.to_radians(f32(90)), Vec3{0.0, 0.0, 1.0})
	ubo.view = linalg.matrix4_look_at_f32(Vec3{2, 2, 2}, Vec3{0, 0, 0}, Vec3{0, 0, 1})
	ubo.proj = linalg.matrix4_perspective_f32(
		linalg.to_radians(f32(45)),
		f32(engine.swapchain_width) / f32(engine.swapchain_height),
		0.1,
		10.0,
		true,
	)
	ubo.proj[1][1] *= -1.0

	mem.copy(engine.uniform_buffers_mapped[frame_index], &ubo, size_of(UniformBufferObject))
}

create_geometry_buffer :: proc(engine: ^Engine) {
	vertex_size := vk.DeviceSize(size_of(Vertex) * len(engine.vertices))
	index_size := vk.DeviceSize(size_of(u16) * len(engine.indices))
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
	mem.copy(data, raw_data(engine.vertices), int(vertex_size))
	mem.copy(rawptr(uintptr(data) + uintptr(vertex_size)), raw_data(engine.indices), int(index_size))
	vma.unmap_memory(engine.vma_allocator, staging_allocation)

	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
			vk.BufferCreateInfo {
				sType = .BUFFER_CREATE_INFO,
				size = total_size,
				usage = {.TRANSFER_DST, .VERTEX_BUFFER, .INDEX_BUFFER},
				sharingMode = .EXCLUSIVE,
			},
			vma.Allocation_Create_Info{usage = .Auto, preferred_flags = {.DEVICE_LOCAL}},
			&engine.geometry_buffer,
			&engine.geometry_buffer_allocation,
			nil,
		),
	)

	copy_buffer(engine, staging_buffer, engine.geometry_buffer, total_size)
}


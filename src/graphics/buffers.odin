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


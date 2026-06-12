package graphics

import "core:mem"
import "core:time"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

GpuBuffer :: struct {
	buffer:     vk.Buffer,
	alloc:      vma.Allocation,
	alloc_info: vma.Allocation_Info,
	ptr:        vk.DeviceAddress,
}

Buffer_Flags :: struct {
	usage: vk.BufferUsageFlags,
	alloc: vma.Allocation_Create_Flags,
}

BufferKind :: enum {
	Storage,
	Uniform,
	DynUniform,
	Index,
	Staging,
	Readback,
}

BUFFER_FLAGS := [BufferKind]Buffer_Flags {
	.Storage    = {{.TRANSFER_DST, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, {}},
	.Uniform    = {{.TRANSFER_DST, .UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS}, {}},
	.DynUniform = {{.TRANSFER_DST, .UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS}, {.Mapped, .Host_Access_Random}},
	.Index      = {{.TRANSFER_DST, .INDEX_BUFFER}, {}},
	.Staging    = {{.TRANSFER_SRC}, {.Mapped, .Host_Access_Sequential_Write}},
	.Readback   = {{.TRANSFER_DST}, {.Mapped, .Host_Access_Random}},
}

create_buffer :: proc(engine: ^Engine, size: vk.DeviceSize, kind: BufferKind) -> GpuBuffer {
	buffer_flags := BUFFER_FLAGS[kind]

	gpu_buf: GpuBuffer
	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
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
		gpu_buf.ptr = vk.GetBufferDeviceAddress(engine.device, &addr_info)
	}

	return gpu_buf
}

destroy_buffer :: proc(engine: ^Engine, buffer: GpuBuffer) {
	vma.destroy_buffer(engine.vma_allocator, buffer.buffer, buffer.alloc)
}

buffer_upload :: proc(engine: ^Engine, data: rawptr, size: vk.DeviceSize, kind: BufferKind) -> GpuBuffer {
	staging := create_buffer(engine, size, .Staging)
	defer destroy_buffer(engine, staging)

	mem.copy(staging.alloc_info.mapped_data, data, int(size))

	dest := create_buffer(engine, size, kind)
	buffer_copy(engine, staging.buffer, dest.buffer, size)
	return dest
}

buffer_copy :: proc(engine: ^Engine, src, dst: vk.Buffer, size: vk.DeviceSize) {
	cmd := begin_single_time_commands(engine)
	region := vk.BufferCopy {
		size = size,
	}
	vk.CmdCopyBuffer(cmd, src, dst, 1, &region)
	end_single_time_commands(engine, &cmd)
}

create_scene_data_buffer :: proc(engine: ^Engine) {
	size := vk.DeviceSize(size_of(SceneData))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		engine.scene_data_buffers[i] = create_buffer(engine, size, .DynUniform)
	}
}

update_scene_data_buffer :: proc(engine: ^Engine, frame_index: u64) {
	scene := SceneData {
		view      = camera_get_view_matrix(engine.camera),
		proj      = camera_get_projection_matrix(
			engine.camera,
			f32(engine.swapchain_extent.width) / f32(engine.swapchain_extent.height),
		),
		light_pos = {2.0, 4.0, 3.0, 0.0},
	}
	scene.proj[1][1] *= -1.0
	mem.copy(engine.scene_data_buffers[frame_index].alloc_info.mapped_data, &scene, size_of(SceneData))
}


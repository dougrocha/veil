package graphics

import "core:math/linalg"
import "core:math/rand"
import "core:mem"

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
	MappedUniform,
	MappedStorage,
	Index,
	Staging,
	ParticleSSBO,
}

BUFFER_FLAGS := [BufferKind]Buffer_Flags {
	.Storage       = {{.TRANSFER_DST, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, {}},
	.MappedUniform = {{.TRANSFER_DST, .UNIFORM_BUFFER, .SHADER_DEVICE_ADDRESS}, {.Mapped, .Host_Access_Random}},
	.MappedStorage = {{.TRANSFER_DST, .STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}, {.Mapped, .Host_Access_Random}},
	.Index         = {{.TRANSFER_DST, .INDEX_BUFFER}, {}},
	.Staging       = {{.TRANSFER_SRC}, {.Mapped, .Host_Access_Sequential_Write}},
	.ParticleSSBO  = {{.TRANSFER_DST, .STORAGE_BUFFER, .VERTEX_BUFFER, .SHADER_DEVICE_ADDRESS}, {}},
}

create_buffer :: proc(ctx: ^VulkanContext, size: vk.DeviceSize, kind: BufferKind) -> GpuBuffer {
	buffer_flags := BUFFER_FLAGS[kind]

	gpu_buf: GpuBuffer
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
		gpu_buf.ptr = vk.GetBufferDeviceAddress(ctx.device, &addr_info)
	}

	return gpu_buf
}

destroy_buffer :: proc(ctx: ^VulkanContext, buffer: GpuBuffer) {
	vma.destroy_buffer(ctx.vma_allocator, buffer.buffer, buffer.alloc)
}

upload_buffer :: proc(ctx: ^VulkanContext, data: rawptr, size: vk.DeviceSize, kind: BufferKind) -> GpuBuffer {
	staging := create_buffer(ctx, size, .Staging)
	defer destroy_buffer(ctx, staging)

	mem.copy(staging.alloc_info.mapped_data, data, int(size))

	dest := create_buffer(ctx, size, kind)
	copy_buffer(ctx, staging.buffer, dest.buffer, size)
	return dest
}

copy_buffer :: proc(ctx: ^VulkanContext, src, dst: vk.Buffer, size: vk.DeviceSize) {
	cmd := begin_single_time_commands(ctx)
	region := vk.BufferCopy {
		size = size,
	}
	vk.CmdCopyBuffer(cmd, src, dst, 1, &region)
	end_single_time_commands(ctx, &cmd)
}

create_scene_data_buffer :: proc(engine: ^Engine) {
	size := vk.DeviceSize(size_of(SceneData))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		engine.frame_resources[i].scene_data_buffer = create_buffer(&engine.vk_ctx, size, .MappedUniform)
	}
}

create_particle_buffer :: proc(engine: ^Engine) {
	particles := make([]Particle, PARTICLE_COUNT, context.temp_allocator)
	aspect_ratio := f32(engine.swapchain.extent.height) / f32(engine.swapchain.extent.width)

	for &p in particles {
		x := rand.float32() * 20.0 - 10.0
		y := rand.float32() * 15.0
		z := rand.float32() * 20.0 - 10.0
		p.position = {x, y, z, 1.0}
		p.velocity = {0, -(rand.float32() * 4.0 + 3.0), 0, 0}
		brightness := rand.float32() * 0.3 + 0.7
		p.color = {brightness * 0.6, brightness * 0.8, brightness, 0.8}
	}

	size := vk.DeviceSize(size_of(Particle) * len(particles))
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		engine.frame_resources[i].particle_buffer = upload_buffer(
			&engine.vk_ctx,
			raw_data(particles),
			size,
			.ParticleSSBO,
		)
	}
}

update_scene_data_buffer :: proc(engine: ^Engine) {
	frame_index := current_frame_res_index(engine)
	scene := SceneData {
		view                    = camera_get_view_matrix(engine.camera),
		proj                    = camera_get_projection_matrix(
			engine.camera,
			f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height),
		),
		point_lights            = engine.point_lights,
		point_light_count       = engine.point_light_count,
		directional_lights      = engine.directional_lights,
		directional_light_count = engine.directional_light_count,
		spot_lights             = engine.spot_lights,
		spot_light_count        = engine.spot_light_count,
		cam_pos                 = engine.camera.position,
		ambient_light           = engine.ambient_light,
	}
	scene.proj[1][1] *= -1.0
	scene.delta_time = engine.clock.delta_time

	light_fov: f32 = 90.0
	light_near: f32 = 0.1
	light_far: f32 = 100.0
	scene.shadow_near = light_near
	scene.shadow_far = light_far
	light_proj := linalg.matrix4_perspective_f32(linalg.to_radians(light_fov), 1.0, light_near, light_far)

	shadow_light_count := min(int(engine.point_light_count), MAX_SHADOW_LIGHTS)
	for light_i in 0 ..< shadow_light_count {
		light := engine.point_lights[light_i]
		for face_dir, face_i in CUBE_FACE_DIRS {
			light_view := linalg.matrix4_look_at(light.pos, light.pos + face_dir.target, face_dir.up)
			scene.light_view_proj[light_i][face_i] = light_proj * light_view
		}
	}

	mem.copy(engine.frame_resources[frame_index].scene_data_buffer.alloc_info.mapped_data, &scene, size_of(SceneData))
}


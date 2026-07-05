package graphics

import "core:math"
import "core:math/linalg"
import "core:math/rand"
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

buffer_create :: proc($T: typeid, ctx: ^VulkanContext, count: int, kind: BufferKind) -> GpuBuffer(T) {
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

buffer_destroy :: proc(ctx: ^VulkanContext, buffer: GpuBuffer($T)) {
	vma.destroy_buffer(ctx.vma_allocator, buffer.buffer, buffer.alloc)
}

buffer_upload :: proc(ctx: ^VulkanContext, data: []$T, kind: BufferKind) -> GpuBuffer(T) {
	size := vk.DeviceSize(size_of(T) * len(data))

	staging := buffer_create(T, ctx, len(data), .Staging)
	defer buffer_destroy(ctx, staging)

	mem.copy(staging.alloc_info.mapped_data, raw_data(data), int(size))

	dest := buffer_create(T, ctx, len(data), kind)
	buffer_copy(ctx, staging.buffer, dest.buffer, size)
	return dest
}

buffer_copy :: proc(ctx: ^VulkanContext, src, dst: vk.Buffer, size: vk.DeviceSize) {
	cmd := begin_single_time_commands(ctx)
	region := vk.BufferCopy {
		size = size,
	}
	vk.CmdCopyBuffer(cmd, src, dst, 1, &region)
	end_single_time_commands(ctx, &cmd)
}

create_scene_data_buffer :: proc(engine: ^Engine) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		engine.frame_resources[i].scene_data_buffer = buffer_create(SceneData, &engine.vk_ctx, 1, .MappedUniform)
	}
}

create_transforms_buffer :: proc(engine: ^Engine) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		engine.frame_resources[i].transforms_buffer = buffer_create(
			GpuTransform,
			&engine.vk_ctx,
			MAX_MODEL_INSTANCES,
			.MappedStorage,
		)
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

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		engine.frame_resources[i].particle_buffer = buffer_upload(&engine.vk_ctx, particles, .ParticleSSBO)
	}
}

scene_data_buffer_update :: proc(engine: ^Engine) {
	frame_index := current_frame_res_index(engine)
	aspect := f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height)
	scene := SceneData {
		view                    = camera_get_view_matrix(engine.scene.camera),
		proj                    = camera_get_projection_matrix(engine.scene.camera, aspect),
		point_lights            = engine.scene.point_lights,
		point_light_count       = engine.scene.point_light_count,
		directional_lights      = engine.scene.directional_lights,
		directional_light_count = engine.scene.directional_light_count,
		spot_lights             = engine.scene.spot_lights,
		spot_light_count        = engine.scene.spot_light_count,
		cam_pos                 = engine.scene.camera.position,
		ambient_light           = engine.scene.ambient_light,
	}
	scene.proj[1][1] *= -1.0
	scene.delta_time = engine.clock.delta_time

	light_fov: f32 = 90.0
	light_near: f32 = 0.1
	light_far: f32 = 100.0
	scene.shadow_near = light_near
	scene.shadow_far = light_far
	// No Y-flip here: unlike the main camera projection, this feeds a cube face render
	// target that's later sampled by direction via SamplerCube, which uses Vulkan's
	// fixed per-face UV convention rather than our own projected coordinates. Flipping Y
	// mirrors what's rasterized into each face relative to what that convention expects,
	// so lookups read the wrong texel.
	light_proj := linalg.matrix4_perspective_f32(linalg.to_radians(light_fov), 1.0, light_near, light_far)

	shadow_light_count := min(int(engine.scene.point_light_count), MAX_SHADOW_LIGHTS)
	for light_i in 0 ..< shadow_light_count {
		light := engine.scene.point_lights[light_i]
		for face_dir, face_i in CUBE_FACE_DIRS {
			light_view := linalg.matrix4_look_at(light.pos, light.pos + face_dir.target, face_dir.up)
			scene.light_view_proj[light_i][face_i] = light_proj * light_view
		}
	}

	dir_count := min(int(engine.scene.directional_light_count), MAX_SHADOW_LIGHTS)
	for light_i in 0 ..< dir_count {
		light := engine.scene.directional_lights[light_i]

		up := Vec3{0, 1, 0}
		if abs(light.direction.y) > 0.999 do up = {0, 0, 1}

		// Fit the light's ortho volume to the camera's view frustum: tighter than a
		// fixed-size box, and using a bounding sphere (orientation-independent) keeps
		// the extent stable as the camera rotates, so only the center needs snapping.
		// Clamp to the shadow-relevant distance rather than the camera's real draw
		// distance (which can be huge, e.g. 5000) — otherwise the ortho volume balloons
		// and the scene's actual depth range collapses into a sliver of [near, far],
		// leaving barely any contrast in the shadow map.
		shadow_camera := engine.scene.camera
		shadow_camera.far = min(shadow_camera.far, light_far)
		corners := frustum_corners_from_camera(&shadow_camera, aspect)

		center := Vec3{0, 0, 0}
		for c in corners do center += c
		center /= 8

		radius: f32 = 0
		for c in corners do radius = max(radius, linalg.length(c - center))

		// Snap the center to texel-sized steps in light space so it doesn't shimmer
		// as the camera moves.
		texel_size := (radius * 2) / f32(SHADOW_MAP_SIZE)
		snap_view := linalg.matrix4_look_at(Vec3{0, 0, 0}, light.direction, up, true)
		center_light_space := (snap_view * Vec4{center.x, center.y, center.z, 1.0}).xyz
		center_light_space.x = math.floor(center_light_space.x / texel_size) * texel_size
		center_light_space.y = math.floor(center_light_space.y / texel_size) * texel_size
		center = (linalg.inverse(snap_view) * Vec4{center_light_space.x, center_light_space.y, center_light_space.z, 1.0}).xyz

		eye := center - light.direction * radius * 2
		dir_view := linalg.matrix4_look_at(eye, center, up, true)

		dir_proj := linalg.matrix_ortho3d(-radius, radius, -radius, radius, light_near, radius * 4)
		dir_proj[2].z *= 0.5
		dir_proj[3].z = dir_proj[3].z * 0.5 + 0.5

		scene.dir_light_view_proj[light_i] = dir_proj * dir_view
	}

	mem.copy(engine.frame_resources[frame_index].scene_data_buffer.alloc_info.mapped_data, &scene, size_of(SceneData))
}


package graphics

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"

import "backend"

FrameData :: struct {
	scene_data_buffer: backend.GpuBuffer(SceneData),
	particle_buffer:   backend.GpuBuffer(Particle),
	transforms_buffer: backend.GpuBuffer(GpuTransform),
}

frame_data_create :: proc(engine: ^Engine) {
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		engine.frame_data[i].scene_data_buffer = backend.buffer_create(SceneData, &engine.vk_ctx, 1, .MappedUniform)
		engine.frame_data[i].transforms_buffer = backend.buffer_create(
			GpuTransform,
			&engine.vk_ctx,
			MAX_MODEL_INSTANCES,
			.MappedStorage,
		)
	}

	create_particle_buffer(engine)
}

frame_data_destroy :: proc(engine: ^Engine) {
	for &res in engine.frame_data {
		backend.buffer_destroy(&engine.vk_ctx, res.scene_data_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.particle_buffer)
		backend.buffer_destroy(&engine.vk_ctx, res.transforms_buffer)
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

	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		engine.frame_data[i].particle_buffer = backend.buffer_upload(&engine.vk_ctx, particles, .ParticleSSBO)
	}
}

scene_data_buffer_update :: proc(engine: ^Engine) {
	frame_index := current_frame_res_index(engine)
	aspect := f32(engine.swapchain.extent.width) / f32(engine.swapchain.extent.height)
	active_camera := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	scene := SceneData {
		view                    = camera_get_view_matrix(active_camera^),
		proj                    = camera_get_projection_matrix(active_camera^, aspect),
		point_lights            = engine.scene.point_lights,
		point_light_count       = engine.scene.point_light_count,
		directional_lights      = engine.scene.directional_lights,
		directional_light_count = engine.scene.directional_light_count,
		spot_lights             = engine.scene.spot_lights,
		spot_light_count        = engine.scene.spot_light_count,
		cam_pos                 = active_camera.position,
		ambient_light           = engine.scene.ambient_light,
	}
	scene.time_info = engine.time_info

	light_fov: f32 = 90.0
	light_near: f32 = 0.1
	light_far: f32 = 100.0
	scene.shadow_near = light_near
	scene.shadow_far = light_far

	// cube face orientation follows the cube-map sampling convention (CUBE_FACE_DIRS), not screen y
	light_proj := matrix4_perspective_z0_f32(
		linalg.to_radians(light_fov),
		1.0,
		light_near,
		light_far,
		flip_y_axis = false,
	)

	shadow_light_count := min(int(engine.scene.point_light_count), MAX_POINT_LIGHTS)
	for light_i in 0 ..< shadow_light_count {
		light := engine.scene.point_lights[light_i]
		for face_dir, face_i in CUBE_FACE_DIRS {
			light_view := linalg.matrix4_look_at(light.pos, light.pos + face_dir.target, face_dir.up)
			scene.point_light_view_proj[light_i][face_i] = light_proj * light_view
		}
	}

	dir_count := min(int(engine.scene.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	for light_i in 0 ..< dir_count {
		light := engine.scene.directional_lights[light_i]

		up := Vec3{0, 1, 0}
		if abs(light.direction.y) > 0.999 do up = {0, 0, 1}

		shadow_camera := active_camera^
		shadow_camera.far = min(shadow_camera.far, light_far)
		corners := frustum_corners_from_camera(&shadow_camera, aspect)

		center := Vec3{0, 0, 0}
		for c in corners do center += c
		center /= 8

		radius: f32 = 0
		for c in corners do radius = max(radius, linalg.length(c - center))

		texel_size := (radius * 2) / f32(SHADOW_MAP_SIZE)
		snap_view := linalg.matrix4_look_at(Vec3{0, 0, 0}, light.direction, up, true)
		center_light_space := (snap_view * Vec4{center.x, center.y, center.z, 1.0}).xyz
		center_light_space.x = math.floor(center_light_space.x / texel_size) * texel_size
		center_light_space.y = math.floor(center_light_space.y / texel_size) * texel_size
		center =
			(linalg.inverse(snap_view) * Vec4{center_light_space.x, center_light_space.y, center_light_space.z, 1.0}).xyz

		eye := center - light.direction * radius * 2
		dir_view := linalg.matrix4_look_at(eye, center, up, true)

		dir_proj := matrix4_ortho3d_z0_f32(-radius, radius, -radius, radius, light_near, radius * 4)

		scene.shadow_2d_view_proj[light_i] = dir_proj * dir_view
	}

	// Spot lights live in the second half of the 2D shadow atlas, after the directional slots.
	spot_count := min(int(engine.scene.spot_light_count), MAX_SPOT_LIGHTS)
	for light_i in 0 ..< spot_count {
		light := engine.scene.spot_lights[light_i]

		up := Vec3{0, 1, 0}
		if abs(light.direction.y) > 0.999 do up = {0, 0, 1}

		// outer_cutoff is stored as a cosine; the cone's full angle is the fov
		spot_fov := 2 * math.acos(light.outer_cutoff)
		spot_view := linalg.matrix4_look_at(light.pos, light.pos + light.direction, up)
		spot_proj := matrix4_perspective_z0_f32(spot_fov, 1.0, light_near, light_far)

		scene.shadow_2d_view_proj[MAX_DIRECTIONAL_LIGHTS + light_i] = spot_proj * spot_view
	}

	mem.copy(engine.frame_data[frame_index].scene_data_buffer.alloc_info.mapped_data, &scene, size_of(SceneData))
}


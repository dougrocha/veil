package graphics

import "backend"

gpu_point_light :: proc(light: PointLight) -> GpuPointLight {
	return {
		position_range = {light.pos.x, light.pos.y, light.pos.z, light.range},
		color_shadow_near = {light.color.x, light.color.y, light.color.z, light.shadow_near},
		attenuation_diffuse = {light.constant, light.linear, light.quadratic, light.diffuse_intensity},
		specular_reserved = {light.specular_intensity, 0, 0, 0},
	}
}

gpu_directional_light :: proc(light: DirectionalLight) -> GpuDirectionalLight {
	return {
		direction_diffuse = {light.direction.x, light.direction.y, light.direction.z, light.diffuse_intensity},
		color_specular = {light.color.x, light.color.y, light.color.z, light.specular_intensity},
		shadow_maximum_reserved = {light.shadow_maximum_distance, 0, 0, 0},
	}
}

gpu_spot_light :: proc(light: SpotLight) -> GpuSpotLight {
	return {
		position_range = {light.pos.x, light.pos.y, light.pos.z, light.range},
		direction_inner = {light.direction.x, light.direction.y, light.direction.z, light.inner_cutoff},
		color_outer = {light.color.x, light.color.y, light.color.z, light.outer_cutoff},
		attenuation = {light.shadow_near, light.constant, light.linear, light.quadratic},
		intensity = {light.diffuse_intensity, light.specular_intensity, 0, 0},
	}
}

// Writes the scene header fields and the active part of each light array into the per-frame mapped
// SceneData, one field at a time. Light array entries past the uploaded count are not written, and the
// shaders loop only to these counts, so the stale tail is never read.
scene_data_buffer_update :: proc(engine: ^Engine, packet: ^FramePacket) {
	frame_index := backend.frame_slot(&engine.vk_ctx)
	buf := engine.frame_data[frame_index].scene_data_buffer
	ctx := &engine.vk_ctx
	aspect := render_aspect(engine)
	// With a color background nothing samples the sky cube; the black default keeps the slot valid.
	sky := engine.texture_system.defaults[.Black_Cube]
	if cube, ok := packet.background.(TextureHandle); ok do sky = cube
	active_camera := &packet.camera
	plan := &engine.shadows.plan

	point_count := min(int(packet.lights.point_light_count), MAX_POINT_LIGHTS)
	directional_count := min(int(packet.lights.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	spot_count := min(int(packet.lights.spot_light_count), MAX_SPOT_LIGHTS)

	backend.buffer_write_value_at(ctx, buf, int(offset_of(SceneData, view)), camera_get_view_matrix(active_camera^))
	backend.buffer_write_value_at(
		ctx,
		buf,
		int(offset_of(SceneData, proj)),
		camera_get_projection_matrix(active_camera^, aspect),
	)
	backend.buffer_write_value_at(ctx, buf, int(offset_of(SceneData, point_light_view_proj)), plan.point_view_proj)
	backend.buffer_write_value_at(ctx, buf, int(offset_of(SceneData, shadow_2d_view_proj)), plan.shadow_2d_view_proj)
	backend.buffer_write_value_at(ctx, buf, int(offset_of(SceneData, shadow_cascade_data)), plan.cascade_data)

	cam_pos_shadow_map_size := Vec4 {
		active_camera.position.x,
		active_camera.position.y,
		active_camera.position.z,
		f32(SHADOW_MAP_SIZE),
	}
	backend.buffer_write_value_at(
		ctx,
		buf,
		int(offset_of(SceneData, cam_pos_shadow_map_size)),
		cam_pos_shadow_map_size,
	)
	backend.buffer_write_value_at(
		ctx,
		buf,
		int(offset_of(SceneData, time_info)),
		GpuTimeInfo {
			time = packet.time,
			delta_time = packet.delta_time,
			frame_count = engine.frame_count,
			_reserved = 0,
		},
	)

	backend.buffer_write_value_at(ctx, buf, int(offset_of(SceneData, point_light_count)), u32(point_count))
	backend.buffer_write_value_at(ctx, buf, int(offset_of(SceneData, directional_light_count)), u32(directional_count))
	backend.buffer_write_value_at(ctx, buf, int(offset_of(SceneData, spot_light_count)), u32(spot_count))
	backend.buffer_write_value_at(ctx, buf, int(offset_of(SceneData, skybox_cube)), texture_cube_slot(engine, sky))
	backend.buffer_write_value_at(
		ctx,
		buf,
		int(offset_of(SceneData, ambient_light)),
		GpuAmbientLight {
			color_brightness = {
				packet.lights.ambient_light.color.x,
				packet.lights.ambient_light.color.y,
				packet.lights.ambient_light.color.z,
				packet.lights.ambient_light.brightness,
			},
		},
	)
	backend.buffer_write_value_at(
		ctx,
		buf,
		int(offset_of(SceneData, debug_settings)),
		GpuDebugSettings {
			show_cascades = u32(engine.settings.cascade_colors),
			disable_shadows = u32(!engine.settings.shadows),
			light_mask = transmute(u32)engine.settings.lights,
			_reserved = 0,
		},
	)

	point_lights := make([]GpuPointLight, point_count, context.temp_allocator)
	for i in 0 ..< point_count do point_lights[i] = gpu_point_light(packet.lights.point_lights[i])
	backend.buffer_write_at(ctx, buf, int(offset_of(SceneData, point_lights)), point_lights)

	directional_lights := make([]GpuDirectionalLight, directional_count, context.temp_allocator)
	for i in 0 ..< directional_count do directional_lights[i] = gpu_directional_light(packet.lights.directional_lights[i])
	backend.buffer_write_at(ctx, buf, int(offset_of(SceneData, directional_lights)), directional_lights)

	spot_lights := make([]GpuSpotLight, spot_count, context.temp_allocator)
	for i in 0 ..< spot_count do spot_lights[i] = gpu_spot_light(packet.lights.spot_lights[i])
	backend.buffer_write_at(ctx, buf, int(offset_of(SceneData, spot_lights)), spot_lights)
}

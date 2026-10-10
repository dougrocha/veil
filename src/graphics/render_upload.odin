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

scene_data_buffer_update :: proc(engine: ^Engine, packet: ^FramePacket) {
	frame_index := backend.frame_slot(&engine.vk_ctx)
	aspect := render_aspect(engine)
	// With a color background nothing samples the sky cube; the black default keeps the slot valid.
	sky := engine.texture_system.defaults[.Black_Cube]
	if cube, ok := packet.background.(TextureHandle); ok do sky = cube
	active_camera := &packet.camera
	data := SceneData {
		view = camera_get_view_matrix(active_camera^),
		proj = camera_get_projection_matrix(active_camera^, aspect),
		point_light_count = packet.lights.point_light_count,
		directional_light_count = packet.lights.directional_light_count,
		spot_light_count = packet.lights.spot_light_count,
		skybox_cube = texture_cube_slot(engine, sky),
		cam_pos_shadow_map_size = {active_camera.position.x, active_camera.position.y, active_camera.position.z, 0},
		ambient_light = {
			color_brightness = {
				packet.lights.ambient_light.color.x,
				packet.lights.ambient_light.color.y,
				packet.lights.ambient_light.color.z,
				packet.lights.ambient_light.brightness,
			},
		},
		debug_settings = {
			show_cascades = u32(engine.settings.cascade_colors),
			disable_shadows = u32(!engine.settings.shadows),
			light_mask = transmute(u32)engine.settings.lights,
			_reserved = 0,
		},
	}
	data.time_info = {
		time        = packet.time,
		delta_time  = packet.delta_time,
		frame_count = engine.frame_count,
		_reserved   = 0,
	}
	data.cam_pos_shadow_map_size.w = f32(SHADOW_MAP_SIZE)
	for i in 0 ..< MAX_POINT_LIGHTS do data.point_lights[i] = gpu_point_light(packet.lights.point_lights[i])
	for i in 0 ..< MAX_DIRECTIONAL_LIGHTS do data.directional_lights[i] = gpu_directional_light(packet.lights.directional_lights[i])
	for i in 0 ..< MAX_SPOT_LIGHTS do data.spot_lights[i] = gpu_spot_light(packet.lights.spot_lights[i])

	plan := &engine.shadows.plan
	data.shadow_2d_view_proj = plan.shadow_2d_view_proj
	data.point_light_view_proj = plan.point_view_proj
	data.shadow_cascade_data = plan.cascade_data

	backend.buffer_write(&engine.vk_ctx, engine.frame_data[frame_index].scene_data_buffer, data)
}

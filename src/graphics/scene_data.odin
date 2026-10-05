package graphics

import "core:mem"

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

scene_data_buffer_update :: proc(engine: ^Engine) {
	frame_index := backend.frame_slot(&engine.vk_ctx)
	aspect := render_aspect(engine)
	active_camera := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	scene := SceneData {
		view = camera_get_view_matrix(active_camera^),
		proj = camera_get_projection_matrix(active_camera^, aspect),
		point_light_count = engine.scene.point_light_count,
		directional_light_count = engine.scene.directional_light_count,
		spot_light_count = engine.scene.spot_light_count,
		skybox_cube = engine.skybox_cube,
		cam_pos_shadow_map_size = {active_camera.position.x, active_camera.position.y, active_camera.position.z, 0},
		ambient_light = {
			color_brightness = {
				engine.scene.ambient_light.color.x,
				engine.scene.ambient_light.color.y,
				engine.scene.ambient_light.color.z,
				engine.scene.ambient_light.brightness,
			},
		},
		debug_settings = {
			show_cascades = engine.debug_settings.show_cascades,
			disable_shadows = engine.debug_settings.disable_shadows,
			light_mask = engine.debug_settings.light_mask,
			_reserved = 0,
		},
	}
	scene.time_info = {
		time        = engine.time_info.time,
		delta_time  = engine.time_info.delta_time,
		frame_count = engine.time_info.frame_count,
		_reserved   = 0,
	}
	scene.cam_pos_shadow_map_size.w = f32(SHADOW_MAP_SIZE)
	for i in 0 ..< MAX_POINT_LIGHTS do scene.point_lights[i] = gpu_point_light(engine.scene.point_lights[i])
	for i in 0 ..< MAX_DIRECTIONAL_LIGHTS do scene.directional_lights[i] = gpu_directional_light(engine.scene.directional_lights[i])
	for i in 0 ..< MAX_SPOT_LIGHTS do scene.spot_lights[i] = gpu_spot_light(engine.scene.spot_lights[i])

	plan := &engine.shadow_plan
	scene.shadow_2d_view_proj = plan.shadow_2d_view_proj
	scene.point_light_view_proj = plan.point_view_proj
	scene.shadow_cascade_data = plan.cascade_data

	mem.copy(
		backend.buffer_contents(&engine.vk_ctx, engine.frame_data[frame_index].scene_data_buffer),
		&scene,
		size_of(SceneData),
	)
}

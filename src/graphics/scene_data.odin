package graphics

import "core:mem"

import "backend"

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
		debug_settings          = engine.debug_settings,
	}
	scene.time_info = engine.time_info

	light_near: f32 = 0.1
	light_far: f32 = 100.0
	scene.shadow_near = light_near
	scene.shadow_far = light_far

	params := ShadowParams {
		aspect = aspect,
		near   = light_near,
		far    = light_far,
	}

	point_count := min(int(engine.scene.point_light_count), MAX_POINT_LIGHTS)
	for light_i in 0 ..< point_count {
		scene.point_light_view_proj[light_i] = compute_point_light_view_proj(
			engine.scene.point_lights[light_i],
			params,
		)
	}

	dir_count := min(int(engine.scene.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	for light_i in 0 ..< dir_count {
		data := compute_directional_shadow_data(engine.scene.directional_lights[light_i], active_camera^, params)
		for i in 0 ..< SHADOW_MAP_CASCADE_COUNT {
			scene.shadow_2d_view_proj[light_i * SHADOW_MAP_CASCADE_COUNT + i] = data.view_proj[i]
		}
		scene.shadow_cascade_splits[light_i] = data.splits
	}

	// Spot lights live in the second half of the 2D shadow atlas, after the directional slots.
	spot_count := min(int(engine.scene.spot_light_count), MAX_SPOT_LIGHTS)
	for light_i in 0 ..< spot_count {
		scene.shadow_2d_view_proj[MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT + light_i] =
			compute_spot_light_view_proj(engine.scene.spot_lights[light_i], params)
	}

	mem.copy(engine.frame_data[frame_index].scene_data_buffer.alloc_info.mapped_data, &scene, size_of(SceneData))
}

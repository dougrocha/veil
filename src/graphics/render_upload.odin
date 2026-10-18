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

// Pure: builds SceneData and the active light arrays without touching a buffer. Light array entries past
// the counts are not written, and the shaders loop only to the counts, so the stale tail is never read.
scene_data_build :: proc(
	input: FrameInput,
	plan: ^ShadowPlan,
) -> (
	scene: SceneData,
	points: []GpuPointLight,
	spots: []GpuSpotLight,
) {
	packet := input.packet
	aspect := extent_aspect(input.targets.extent)
	active_camera := &packet.camera

	point_count := min(int(packet.lights.point_light_count), MAX_POINT_LIGHTS)
	directional_count := min(int(packet.lights.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	spot_count := min(int(packet.lights.spot_light_count), MAX_SPOT_LIGHTS)

	scene.view = camera_get_view_matrix(active_camera^)
	scene.proj = camera_get_projection_matrix(active_camera^, aspect)
	scene.point_light_view_proj = plan.point_view_proj
	scene.shadow_2d_view_proj = plan.shadow_2d_view_proj
	scene.shadow_cascade_data = plan.cascade_data
	scene.cam_pos_shadow_map_size = {
		active_camera.position.x,
		active_camera.position.y,
		active_camera.position.z,
		f32(SHADOW_MAP_SIZE),
	}
	scene.time_info = {
		time        = packet.time,
		delta_time  = packet.delta_time,
		frame_count = input.frame_count,
		_reserved   = 0,
	}

	scene.point_light_count = u32(point_count)
	scene.directional_light_count = u32(directional_count)
	scene.spot_light_count = u32(spot_count)
	scene.skybox_cube = input.sky
	scene.point_lights = input.addresses.point_lights
	scene.spot_lights = input.addresses.spot_lights
	scene.cluster_headers = input.addresses.cluster_headers
	scene.cluster_indices = input.addresses.cluster_indices
	scene.cluster_extent = {f32(input.targets.extent.width), f32(input.targets.extent.height)}
	scene.cluster_near_far = {active_camera.near, active_camera.far}
	scene.ambient_light = {
		color_brightness = {
			packet.lights.ambient_light.color.x,
			packet.lights.ambient_light.color.y,
			packet.lights.ambient_light.color.z,
			packet.lights.ambient_light.brightness,
		},
	}
	scene.debug_settings = {
		show_cascades      = u32(packet.settings.cascade_colors),
		disable_shadows    = u32(!packet.settings.shadows),
		light_mask         = transmute(u32)packet.settings.lights,
		clustered_lighting = u32(packet.settings.clustered_lighting),
	}

	if point_count > 0 {
		points = make([]GpuPointLight, point_count, context.temp_allocator)
		for i in 0 ..< point_count {
			points[i] = gpu_point_light(packet.lights.point_lights[i])
		}
	}
	for i in 0 ..< directional_count {
		scene.directional_lights[i] = gpu_directional_light(packet.lights.directional_lights[i])
	}
	if spot_count > 0 {
		spots = make([]GpuSpotLight, spot_count, context.temp_allocator)
		for i in 0 ..< spot_count {
			spots[i] = gpu_spot_light(packet.lights.spot_lights[i])
		}
	}
	return
}

// The only host writes into this slot's buffers. Copies built data; makes no decisions. The cull and
// overlay data live in their passes, so this looks them up in the list.
frame_upload :: proc(r: ^Recorder, uploads: ^FrameUploads, passes: []Pass, lines: ^LineRenderer, ui: ^UIRenderer) {
	scene := backend.buffer_map_write(r.ctx, r.frame.scene_data_buffer, 0, 1)
	scene[0] = uploads.scene
	if len(uploads.point_lights) > 0 {
		lights := backend.buffer_map_write(r.ctx, r.frame.point_lights_buffer, 0, len(uploads.point_lights))
		copy(lights, uploads.point_lights)
	}
	if len(uploads.spot_lights) > 0 {
		lights := backend.buffer_map_write(r.ctx, r.frame.spot_lights_buffer, 0, len(uploads.spot_lights))
		copy(lights, uploads.spot_lights)
	}
	writes := uploads.transforms
	if len(writes) > 0 {
		first := writes[0].id
		last := writes[len(writes) - 1].id
		dst := backend.buffer_map_write(r.ctx, r.frame.transforms_buffer, int(first), int(last - first + 1))
		for write in writes do dst[write.id - first] = write.value
	}
	layout_upload(r, &uploads.layout)
	for &pass in passes {
		#partial switch &p in pass {
		case MainPass:
			if cull, ok := p.cull.(CullUpload); ok do cull_upload(r, &cull)
		case OverlayPass:
			r.overlay = overlay_upload(r.ctx, lines, ui, &p)
		}
	}
}

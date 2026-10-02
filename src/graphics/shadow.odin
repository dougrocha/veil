package graphics

import "core:math"
import "core:math/linalg"


ShadowParams :: struct {
	aspect: f32,
}

DirectionalShadowData :: struct {
	view_proj: [SHADOW_MAP_CASCADE_COUNT]Mat4x4,
	splits:    Vec4,
	bias:      Vec4,
}

ShadowCascadeData :: struct {
	split: Vec4,
	bias:  Vec4,
}

compute_point_light_view_proj :: proc(light: PointLight) -> [6]Mat4x4 {
	light_proj := matrix4_perspective_z0_f32(
		linalg.to_radians(f32(90.0)),
		1.0,
		light.shadow_near,
		light.range,
		flip_y_axis = false,
	)

	view_proj: [6]Mat4x4
	for face_dir, face_i in CUBE_FACE_DIRS {
		light_view := linalg.matrix4_look_at(light.pos, light.pos + face_dir.target, face_dir.up)
		view_proj[face_i] = light_proj * light_view
	}
	return view_proj
}

compute_directional_shadow_data :: proc(
	light: DirectionalLight,
	camera: Camera,
	params: ShadowParams,
) -> DirectionalShadowData {
	up := Vec3{0, 1, 0}
	if abs(light.direction.y) > 0.999 do up = {0, 0, 1}

	cascade_lambda: f32 = 0.5

	// Cascades are distributed over the shadow range, not the whole view range:
	// a far plane much larger than the scene would otherwise spend most of the
	// cascade budget on depth that holds no geometry.
	near := camera.near
	far := camera.far
	if light.shadow_maximum_distance > 0 {
		far = min(light.shadow_maximum_distance, camera.far)
	}
	far = max(far, near + 1e-4)
	range := far - near
	ratio := far / near

	splits: [SHADOW_MAP_CASCADE_COUNT]f32
	for i in 0 ..< SHADOW_MAP_CASCADE_COUNT {
		p := f32(i + 1) / f32(SHADOW_MAP_CASCADE_COUNT)
		log_split := near * math.pow(ratio, p)
		uniform_split := near + range * p
		splits[i] = cascade_lambda * (log_split - uniform_split) + uniform_split
	}

	data: DirectionalShadowData
	for i in 0 ..< SHADOW_MAP_CASCADE_COUNT {
		shadow_camera := camera

		cascade_near := i == 0 ? near : splits[i - 1]
		cascade_far := splits[i]
		shadow_camera.near = cascade_near
		shadow_camera.far = cascade_far

		corners := frustum_corners_from_camera(&shadow_camera, params.aspect)

		center := Vec3{0, 0, 0}
		for c in corners do center += c
		center /= 8

		radius: f32 = 0
		for c in corners do radius = max(radius, linalg.length(c - center))

		texel_size := (radius * 2) / f32(SHADOW_MAP_SIZE)
		data.bias[i] = texel_size / (radius * 2)

		snap_view := linalg.matrix4_look_at(Vec3{0, 0, 0}, light.direction, up, true)
		center_light_space := (snap_view * Vec4{center.x, center.y, center.z, 1.0}).xyz
		center_light_space.x = math.floor(center_light_space.x / texel_size) * texel_size
		center_light_space.y = math.floor(center_light_space.y / texel_size) * texel_size
		center =
			(linalg.inverse(snap_view) * Vec4{center_light_space.x, center_light_space.y, center_light_space.z, 1.0}).xyz

		eye := center - light.direction * radius
		dir_view := linalg.matrix4_look_at(eye, center, up, true)

		dir_proj := matrix4_ortho3d_z0_f32(-radius, radius, -radius, radius, 0, radius * 2)

		data.view_proj[i] = dir_proj * dir_view
	}

	#assert(SHADOW_MAP_CASCADE_COUNT <= 4, "cascade splits are packed into a Vec4")
	for split, i in splits do data.splits[i] = split
	return data
}

compute_spot_light_view_proj :: proc(light: SpotLight) -> Mat4x4 {
	up := Vec3{0, 1, 0}
	if abs(light.direction.y) > 0.999 do up = {0, 0, 1}

	// outer_cutoff is stored as a cosine; the cone's full angle is the fov
	spot_fov := 2 * math.acos(light.outer_cutoff)
	spot_view := linalg.matrix4_look_at(light.pos, light.pos + light.direction, up)
	spot_proj := matrix4_perspective_z0_f32(spot_fov, 1.0, light.shadow_near, light.range)

	return spot_proj * spot_view
}

package graphics

import "core:math"
import "core:math/linalg"

Plane :: struct {
	normal:   Vec3,
	distance: f32,
}

Frustum :: struct {
	planes: [6]Plane, // order: near, far, left, right, top, bottom
}

// Gribb-Hartmann plane extraction: each frustum plane is a row-combination
// of the view-projection matrix. Works for any camera or light's view-proj.
frustum_from_view_proj :: proc(proj: Mat4x4) -> Frustum {
	frustum: Frustum

	row0 := Vec4{proj[0, 0], proj[1, 0], proj[2, 0], proj[3, 0]}
	row1 := Vec4{proj[0, 1], proj[1, 1], proj[2, 1], proj[3, 1]}
	row2 := Vec4{proj[0, 2], proj[1, 2], proj[2, 2], proj[3, 2]}
	row3 := Vec4{proj[0, 3], proj[1, 3], proj[2, 3], proj[3, 3]}

	raw_planes := [6]Vec4 {
		row3 + row2, // near
		row3 - row2, // far
		row3 + row0, // left
		row3 - row0, // right
		row3 + row1, // bottom
		row3 - row1, // top
	}

	for raw, i in raw_planes {
		normal := Vec3{raw.x, raw.y, raw.z}
		length := linalg.length(normal)
		frustum.planes[i] = Plane {
			normal   = normal / length,
			distance = -raw.w / length,
		}
	}

	return frustum
}

frustum_create_from_camera :: proc(camera: ^Camera, aspect: f32, fov: f32, near: f32, far: f32) -> Frustum {
	frustum: Frustum

	half_v_side := far * math.tan_f32(fov * 0.5)
	half_h_side := half_v_side * aspect

	front_mul_far := far * camera.front

	frustum.planes[0] = {
		normal   = camera.front,
		distance = linalg.dot(camera.front, camera.position + near * camera.front),
	}
	frustum.planes[1] = {
		normal   = -camera.front,
		distance = linalg.dot(-camera.front, camera.position + front_mul_far),
	}

	right_normal := linalg.normalize(linalg.cross(camera.up, front_mul_far + half_h_side * camera.right))
	frustum.planes[2] = {
		normal   = right_normal,
		distance = linalg.dot(right_normal, camera.position),
	}

	left_normal := linalg.normalize(linalg.cross(front_mul_far - half_h_side * camera.right, camera.up))
	frustum.planes[3] = {
		normal   = left_normal,
		distance = linalg.dot(left_normal, camera.position),
	}

	top_normal := linalg.normalize(linalg.cross(front_mul_far + half_v_side * camera.up, camera.right))
	frustum.planes[4] = {
		normal   = top_normal,
		distance = linalg.dot(top_normal, camera.position),
	}

	bottom_normal := linalg.normalize(linalg.cross(camera.right, front_mul_far - half_v_side * camera.up))
	frustum.planes[5] = {
		normal   = bottom_normal,
		distance = linalg.dot(bottom_normal, camera.position),
	}

	return frustum
}

BoundingSphere :: struct {
	center: Vec3,
	radius: f32,
}

// TODO: Create inits
AABB :: struct {
	center:  Vec3,
	extents: Vec3,
}

Volume :: union {
	BoundingSphere,
	AABB,
}

plane_get_signed_distance_to_plane :: proc(plane: Plane, point: Vec3) -> f32 {
	return linalg.dot(plane.normal, point) - plane.distance
}

sphere_is_on_or_forward :: proc(global_sphere: BoundingSphere, plane: Plane) -> bool {
	return plane_get_signed_distance_to_plane(plane, global_sphere.center) > -global_sphere.radius
}

plane_is_on_or_forward :: proc(global_plane: AABB, plane: Plane) -> bool {
	r :=
		global_plane.extents.x * math.abs(plane.normal.x) +
		global_plane.extents.y * math.abs(plane.normal.y) +
		global_plane.extents.z * math.abs(plane.normal.z)

	return -r <= plane_get_signed_distance_to_plane(plane, global_plane.center)
}

volume_is_on_frustum :: proc(frustum: Frustum, volume: Volume, transform: Transform) -> bool {
	switch v in volume {
	case BoundingSphere:
		return sphere_is_on_frustum(frustum, v, transform)
	case AABB:
		return aabb_is_on_frustum(frustum, v, transform)
	case:
		return false
	}
}

sphere_is_on_frustum :: proc(frustum: Frustum, volume: BoundingSphere, transform: Transform) -> bool {
	global_scale := transform_global_scale(transform)

	global_center := transform_matrix(transform) * Vec4{volume.center.x, volume.center.y, volume.center.z, 1.0}

	max_scale := max(global_scale.x, global_scale.y, global_scale.z)

	global_sphere := BoundingSphere{global_center.xyz, volume.radius * max_scale}

	for plane in frustum.planes {
		if !sphere_is_on_or_forward(global_sphere, plane) {
			return false
		}
	}

	return true
}

aabb_is_on_frustum :: proc(frustum: Frustum, volume: AABB, transform: Transform) -> bool {
	global_center := transform_matrix(transform) * Vec4{volume.center.x, volume.center.y, volume.center.z, 1.0}

	right := transform_right(transform) * volume.extents.x
	up := transform_up(transform) * volume.extents.y
	forward := transform_forward(transform) * volume.extents.z

	new_ii :=
		abs(linalg.dot(Vec3{1, 0, 0}, right)) +
		abs(linalg.dot(Vec3{1, 0, 0}, up)) +
		abs(linalg.dot(Vec3{1, 0, 0}, forward))

	new_ij :=
		abs(linalg.dot(Vec3{0, 1, 0}, right)) +
		abs(linalg.dot(Vec3{0, 1, 0}, up)) +
		abs(linalg.dot(Vec3{0, 1, 0}, forward))

	new_ik :=
		abs(linalg.dot(Vec3{0, 0, 1}, right)) +
		abs(linalg.dot(Vec3{0, 0, 1}, up)) +
		abs(linalg.dot(Vec3{0, 0, 1}, forward))

	// No need to divide by scale — this is already based on the AABB's half-extents.
	global_aabb := AABB{global_center.xyz, {new_ii, new_ij, new_ik}}

	for plane in frustum.planes {
		if !plane_is_on_or_forward(global_aabb, plane) {
			return false
		}
	}

	return true
}


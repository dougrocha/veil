package graphics

import "core:math"
import "core:math/linalg"

Plane :: struct {
	normal:   Vec3,
	distance: f32,
}

Frustum :: struct {
	top_face:    Plane,
	bottom_face: Plane,
	right_face:  Plane,
	left_face:   Plane,
	far_face:    Plane,
	near_face:   Plane,
}

frustum_create_from_camera :: proc(camera: ^Camera, aspect: f32, fov: f32, near: f32, far: f32) -> Frustum {
	frustum: Frustum

	half_v_side := far * math.tan_f32(fov * 0.5)
	half_h_side := half_v_side * aspect

	front_mul_far := far * camera.front

	frustum.near_face = {
		normal   = camera.front,
		distance = linalg.dot(camera.front, camera.position + near * camera.front),
	}
	frustum.far_face = {
		normal   = -camera.front,
		distance = linalg.dot(-camera.front, camera.position + front_mul_far),
	}

	right_normal := linalg.normalize(linalg.cross(camera.up, front_mul_far + half_h_side * camera.right))
	frustum.right_face = {
		normal   = right_normal,
		distance = linalg.dot(right_normal, camera.position),
	}

	left_normal := linalg.normalize(linalg.cross(front_mul_far - half_h_side * camera.right, camera.up))
	frustum.left_face = {
		normal   = left_normal,
		distance = linalg.dot(left_normal, camera.position),
	}

	top_normal := linalg.normalize(linalg.cross(camera.right, front_mul_far + half_v_side * camera.up))
	frustum.top_face = {
		normal   = top_normal,
		distance = linalg.dot(top_normal, camera.position),
	}

	bottom_normal := linalg.normalize(linalg.cross(front_mul_far - half_v_side * camera.up, camera.right))
	frustum.bottom_face = {
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
	// global_scale := transform_get_global_scale(transform)

	// global_center := Vec3{transform_matrix(transform) * Vec4{volume.center.x, 1.0}}

	return false
}
aabb_is_on_frustum :: proc(frustum: Frustum, volume: Volume, transform: Transform) -> bool {return false}


package graphics

import "core:math"
import "core:math/linalg"

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Quat :: quaternion128

Mat4x4 :: matrix[4, 4]f32
Mat4x3 :: matrix[4, 3]f32

vec3_splat :: proc(v: f32) -> Vec3 {return {v, v, v}}

Transform :: struct {
	translation: Vec3,
	rotation:    Quat,
	scale:       Vec3,
}

transform_create :: proc(
	translation: Vec3 = {0.0, 0.0, 0.0},
	rotation: Quat = linalg.QUATERNIONF32_IDENTITY,
	scale: Vec3 = {1.0, 1.0, 1.0},
) -> Transform {
	return Transform{translation = translation, rotation = rotation, scale = scale}
}

// Maps a point from local space to world space: scale, then rotate, then translate.
transform_point :: proc(transform: Transform, p: Vec3) -> Vec3 {
	return transform.translation + linalg.quaternion_mul_vector3(transform.rotation, p * transform.scale)
}

// Builds the model matrix by combining translation, rotation, and scale
transform_to_matrix :: proc(transform: Transform) -> Mat4x4 {
	translation := linalg.matrix4_translate(transform.translation)
	rotation := linalg.matrix4_from_quaternion(transform.rotation)
	scale := linalg.matrix4_scale(transform.scale)

	return translation * rotation * scale
}

// Splits an affine matrix back into TRS. Shear (a non-uniformly scaled parent with a rotated
// child) can't be represented and is lost.
transform_from_matrix :: proc(m: Mat4x4) -> Transform {
	x := Vec3{m[0, 0], m[1, 0], m[2, 0]}
	y := Vec3{m[0, 1], m[1, 1], m[2, 1]}
	z := Vec3{m[0, 2], m[1, 2], m[2, 2]}
	scale := Vec3{linalg.length(x), linalg.length(y), linalg.length(z)}
	if linalg.dot(linalg.cross(x, y), z) < 0 do scale.x = -scale.x // mirrored
	x /= scale.x if scale.x != 0 else 1
	y /= scale.y if scale.y != 0 else 1
	z /= scale.z if scale.z != 0 else 1
	rotation := matrix[3, 3]f32{
		x.x, y.x, z.x,
		x.y, y.y, z.y,
		x.z, y.z, z.z,
	}
	return Transform {
		translation = {m[0, 3], m[1, 3], m[2, 3]},
		rotation = linalg.quaternion_from_matrix3(rotation),
		scale = scale,
	}
}

transform_global_scale :: proc(transform: Transform) -> Vec3 {
	return transform.scale
}

transform_right :: proc(transform: Transform) -> Vec3 {
	return linalg.quaternion_mul_vector3(transform.rotation, Vec3{1, 0, 0})
}

transform_up :: proc(transform: Transform) -> Vec3 {
	return linalg.quaternion_mul_vector3(transform.rotation, Vec3{0, 1, 0})
}

transform_forward :: proc(transform: Transform) -> Vec3 {
	return linalg.quaternion_mul_vector3(transform.rotation, Vec3{0, 0, -1})
}


// core:math/linalg's projection procs (matrix4_perspective_f32, matrix_ortho3d)
// produce NDC z in [-1, 1] (GL convention). Vulkan's depth range is [0, 1].
// These are the same constructions with the z-range baked in directly.

// Convert between top-left-origin pixel coordinates and Vulkan NDC (screen-top is -1).
screen_to_ndc :: proc "contextless" (screen, viewport: Vec2) -> Vec2 {
	return screen / viewport * 2 - 1
}

ndc_to_screen :: proc "contextless" (ndc, viewport: Vec2) -> Vec2 {
	return (ndc + 1) * viewport * 0.5
}

@(require_results)
matrix4_perspective_z0_f32 :: proc "contextless" (
	fovy, aspect, near, far: f32,
	flip_z_axis := true,
	flip_y_axis := true,
) -> (
	m: Mat4x4,
) #no_bounds_check {
	tan_half_fovy := math.tan(0.5 * fovy)
	m[0, 0] = 1 / (aspect * tan_half_fovy)
	m[1, 1] = 1 / (tan_half_fovy)
	m[2, 2] = far / (far - near)
	m[3, 2] = +1
	m[2, 3] = -(far * near) / (far - near)

	if flip_z_axis {
		m[2] = -m[2]
	}

	if flip_y_axis {
		m[1][1] *= -1
	}

	return
}

@(require_results)
matrix4_ortho3d_z0_f32 :: proc "contextless" (
	left, right, bottom, top, near, far: f32,
	flip_z_axis := true,
	flip_y_axis := true,
) -> (
	m: Mat4x4,
) #no_bounds_check {
	m[0, 0] = +2 / (right - left)
	m[1, 1] = +2 / (top - bottom)
	m[2, 2] = +1 / (far - near)
	m[0, 3] = -(right + left) / (right - left)
	m[1, 3] = -(top + bottom) / (top - bottom)
	m[2, 3] = -near / (far - near)
	m[3, 3] = 1

	if flip_z_axis {
		m[2] = -m[2]
	}

	if flip_y_axis {
		m[1][1] *= -1
		m[1][3] *= -1 // off-center translation flips with the scale
	}

	return
}

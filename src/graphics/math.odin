package graphics

import "core:math"

import "backend"

// core:math/linalg's projection procs (matrix4_perspective_f32, matrix_ortho3d)
// produce NDC z in [-1, 1] (GL convention). Vulkan's depth range is [0, 1].
// These are the same constructions with the z-range baked in directly.

// Convert between top-left-origin pixel coordinates and the active backend's
// NDC convention. Vulkan's projection maps screen-top to -1, while Metal maps
// it to +1. Keeping that distinction here makes projection and unprojection
// exact inverses everywhere else.
screen_to_ndc :: proc "contextless" (screen, viewport: Vec2) -> Vec2 {
	ndc := screen / viewport * 2 - 1
	when backend.VEIL_METAL {
		ndc.y = -ndc.y
	}
	return ndc
}

ndc_to_screen :: proc "contextless" (ndc, viewport: Vec2) -> Vec2 {
	result := ndc
	when backend.VEIL_METAL {
		result.y = -result.y
	}
	return (result + 1) * viewport * 0.5
}

@(require_results)
matrix4_perspective_z0_f32 :: proc "contextless" (
	fovy, aspect, near, far: f32,
	flip_z_axis := true,
	flip_y_axis := backend.VEIL_VULKAN,
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
	flip_y_axis := backend.VEIL_VULKAN,
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

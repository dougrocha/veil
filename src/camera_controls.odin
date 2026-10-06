package main

import "core:math"
import "core:math/linalg"
import gfx "veil:graphics"

camera_process_keyboard :: proc(c: ^gfx.Camera, direction: CameraMovement, delta_time: f32) {
	velocity := c.movement_speed * delta_time

	// Dolly movement is invisible in orthographic projection (no perspective
	// divide), so forward/backward zooms the ortho extent instead. Takes
	// priority over orbit distance below: in ortho, distance alone wouldn't
	// change what's visible either.
	if p, ok := &c.projection.(gfx.Ortho_Projection); ok {
		switch direction {
		case .Forward:
			ortho_scaling_mode_zoom(&p.scaling_mode, -velocity)
			return
		case .Backward:
			ortho_scaling_mode_zoom(&p.scaling_mode, velocity)
			return
		case .Left, .Right, .Up, .Down:
		}
	}

	if c.control_type == .Orbit {
		switch direction {
		case .Forward:
			c.orbit_distance = max(c.orbit_distance - velocity, MIN_ORBIT_DISTANCE)
			gfx.camera_update_vectors(c)
			return
		case .Backward:
			c.orbit_distance += velocity
			gfx.camera_update_vectors(c)
			return
		case .Left:
			c.orbit_target -= c.right * velocity
			gfx.camera_update_vectors(c)
			return
		case .Right:
			c.orbit_target += c.right * velocity
			gfx.camera_update_vectors(c)
			return
		case .Up:
			c.orbit_target += c.up * velocity
			gfx.camera_update_vectors(c)
			return
		case .Down:
			c.orbit_target -= c.up * velocity
			gfx.camera_update_vectors(c)
			return
		}
	}

	switch direction {
	case .Forward:
		c.position += c.front * velocity
	case .Backward:
		c.position -= c.front * velocity
	case .Left:
		c.position -= c.right * velocity
	case .Right:
		c.position += c.right * velocity
	case .Up:
		c.position += c.up * velocity
	case .Down:
		c.position -= c.up * velocity
	}
}

ortho_scaling_mode_zoom :: proc(mode: ^gfx.Ortho_Scaling_Mode, delta: f32) {
	switch &m in mode {
	case gfx.Fixed_Size:
		m.width = max(m.width + delta, MIN_ORTHO_EXTENT)
		m.height = max(m.height + delta, MIN_ORTHO_EXTENT)
	case gfx.Fixed_Vertical:
		m.height = max(m.height + delta, MIN_ORTHO_EXTENT)
	}
}

camera_process_mouse_movement :: proc(c: ^gfx.Camera, x_offset: f32, y_offset: f32, constrain_pitch: bool = true) {
	c.yaw += x_offset * c.mouse_sensitivity
	c.pitch += y_offset * c.mouse_sensitivity

	if constrain_pitch {
		c.pitch = clamp(c.pitch, -89.0, 89.0)
	}

	gfx.camera_update_vectors(c)
}

camera_process_mouse_scroll :: proc(c: ^gfx.Camera, y_offset: f32) {
	if p, ok := &c.projection.(gfx.Perspective_Projection); ok {
		p.fov_y = clamp(p.fov_y - linalg.to_radians(y_offset), linalg.to_radians(f32(1)), linalg.to_radians(f32(90)))
	}
}

CameraMovement :: enum {
	Forward,
	Backward,
	Left,
	Right,
	Up,
	Down,
}

MIN_ORTHO_EXTENT :: 0.1
MIN_ORBIT_DISTANCE :: 0.1

// The transform a camera's rig describes: at position, looking along front (the camera's -z).
// Fly and orbit controls edit the rig; main writes this back to the camera entity every frame.
camera_rig_transform :: proc(c: gfx.Camera) -> gfx.Transform {
	basis := matrix[3, 3]f32{
		c.right.x, c.up.x, -c.front.x,
		c.right.y, c.up.y, -c.front.y,
		c.right.z, c.up.z, -c.front.z,
	}
	return gfx.transform_create(translation = c.position, rotation = linalg.quaternion_from_matrix3(basis))
}

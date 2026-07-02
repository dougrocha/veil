package graphics

import "core:math/linalg"

// right-hand rule: thumb=+X (right), index=+Y (up), middle=+Z (toward you/outside screen)
CameraType :: enum {
	FirstPerson,
	ThirdPerson,
	Orbit,
	Free,
}

Camera :: struct {
	// Spatial positioning and orientation vectors using right hand coordinate system
	// These form the camera's local coordinate system in world space
	position:          Vec3,
	// these positions (front, up, right) are vectors that point in that
	// direction depending on where the camera is looking
	// not to be confused with x, y, z coordinate plane
	front:             Vec3,
	up:                Vec3,
	right:             Vec3,
	world_up:          Vec3, // acts as a reference point, typically pointing along the world y-axis

	// Rotation representation using euler angles
	yaw:               f32, // horizonal rotation around the world up-axis (left-right)
	pitch:             f32, // vertical rotation around right-axis (up-down)

	// user stuff
	movement_speed:    f32,
	mouse_sensitivity: f32,
	zoom:              f32, // fov control for perspective
}

camera_create :: proc(
	position: Vec3 = {0, 0, 0},
	world_up: Vec3 = {0, 1, 0},
	yaw: f32 = -90,
	pitch: f32 = 0,
) -> Camera {
	c := Camera {
		position          = position,
		world_up          = world_up,
		yaw               = yaw,
		pitch             = pitch,
		movement_speed    = 10,
		mouse_sensitivity = 0.1,
		zoom              = 45,
	}
	camera_update_vectors(&c)
	return c
}

camera_update_vectors :: proc(camera: ^Camera) {
	front := Vec3 {
		linalg.cos(linalg.to_radians(camera.yaw)) * linalg.cos(linalg.to_radians(camera.pitch)),
		linalg.sin(linalg.to_radians(camera.pitch)),
		linalg.sin(linalg.to_radians(camera.yaw)) * linalg.cos(linalg.to_radians(camera.pitch)),
	}
	camera.front = linalg.normalize(front)

	camera.right = linalg.normalize(linalg.cross(camera.front, camera.world_up))
	camera.up = linalg.normalize(linalg.cross(camera.right, camera.front))
}

camera_get_view_matrix :: proc(c: Camera) -> Mat4x4 {
	return linalg.matrix4_look_at_f32(c.position, c.position + c.front, c.up)
}

camera_get_projection_matrix :: proc(
	c: Camera,
	aspect_ratio: f32,
	near_plane: f32 = 0.1,
	far_plane: f32 = 5000.0,
) -> Mat4x4 {
	return linalg.matrix4_perspective_f32(linalg.to_radians(c.zoom), aspect_ratio, near_plane, far_plane, true)
}

CameraMovement :: enum {
	Forward,
	Backward,
	Left,
	Right,
	Up,
	Down,
}

camera_process_keyboard :: proc(c: ^Camera, direction: CameraMovement, delta_time: f32) {
	velocity := c.movement_speed * delta_time

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

camera_process_mouse_movement :: proc(c: ^Camera, x_offset: f32, y_offset: f32, constrain_pitch: bool = true) {
	c.yaw += x_offset * c.mouse_sensitivity
	c.pitch += y_offset * c.mouse_sensitivity

	if constrain_pitch {
		c.pitch = clamp(c.pitch, -89.0, 89.0)
	}

	camera_update_vectors(c)
}

camera_process_mouse_scroll :: proc(c: ^Camera, y_offset: f32) {
	c.zoom = clamp(c.zoom - y_offset, 1.0, 90.0)
}


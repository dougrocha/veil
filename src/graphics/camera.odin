package graphics

import "core:log"
import "core:math/linalg"

// right-hand rule: thumb=+X (right), index=+Y (up), middle=+Z (toward you/outside screen)

DEFAULT_CAMERA_NAME :: "default_camera"

CameraSystemConfig :: struct {
	max_camera_count: int,
}

CameraSystem :: struct {
	config:         CameraSystemConfig,
	default_camera: Camera,
	cameras:        map[string]Camera,
}

camera_system_create :: proc(config: CameraSystemConfig) -> CameraSystem {
	cs := CameraSystem {
		config         = config,
		default_camera = camera_create(),
	}
	reserve(&cs.cameras, config.max_camera_count)
	return cs
}

camera_system_destroy :: proc(cs: ^CameraSystem) {
	delete(cs.cameras)
}

camera_system_add_camera :: proc(cs: ^CameraSystem, name: string, camera: Camera) {
	log.assertf(
		len(cs.cameras) < cs.config.max_camera_count,
		"camera system full (max %v)",
		cs.config.max_camera_count,
	)
	cam := camera
	cam.name = name
	cs.cameras[name] = cam
}

camera_system_get_camera :: proc(cs: ^CameraSystem, name: string) -> ^Camera {
	if name == DEFAULT_CAMERA_NAME {
		return &cs.default_camera
	}

	cam, ok := &cs.cameras[name]
	log.assertf(ok, "camera (%v) not found", name)
	return cam
}

camera_system_delete_camera :: proc(cs: ^CameraSystem, name: string) {
	if name == DEFAULT_CAMERA_NAME {
		log.warnf("cannot delete default camera")
		return
	}

	if !(name in cs.cameras) {
		log.assertf(false, "camera (%v) not found", name)
		return
	}

	delete_key(&cs.cameras, name)
}

camera_system_get_default :: proc(cs: ^CameraSystem) -> ^Camera {
	return &cs.default_camera
}

// TODO: wire up later
CameraType :: enum {
	FirstPerson,
	ThirdPerson,
	Orbit,
	Free,
}

Perspective_Projection :: struct {
	fov_y: f32, // fov control for perspective, in radians
}

// Fixed_Size gives explicit world-space extents; Fixed_Vertical locks the
// vertical extent and derives width from aspect. More modes (window-relative
// pixel matching, fit-inside/outside) can be added here for UI use later.
Fixed_Size :: struct {
	width, height: f32,
}

Fixed_Vertical :: struct {
	height: f32,
}

Ortho_Scaling_Mode :: union {
	Fixed_Size,
	Fixed_Vertical,
}

Ortho_Projection :: struct {
	scaling_mode:              Ortho_Scaling_Mode,
	// Derived world-space extents; recomputed from scaling_mode each frame,
	// not meant to be set directly.
	left, right, bottom, top:  f32,
}

Projection :: union {
	Perspective_Projection,
	Ortho_Projection,
}

// Computes ortho extents from a scaling mode and the current viewport aspect
// (width / height). Shared by camera_get_projection_matrix and
// frustum_create_from_camera so both stay in sync.
ortho_extents_from_scaling_mode :: proc(mode: Ortho_Scaling_Mode, aspect: f32) -> (left, right, bottom, top: f32) {
	switch m in mode {
	case Fixed_Size:
		left, right = -m.width * 0.5, m.width * 0.5
		bottom, top = -m.height * 0.5, m.height * 0.5
	case Fixed_Vertical:
		half_h := m.height * 0.5
		half_w := half_h * aspect
		left, right = -half_w, half_w
		bottom, top = -half_h, half_h
	}
	return
}

Camera :: struct {
	name:              string,

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

	// projection stuff
	projection:        Projection,
	near:              f32,
	far:               f32,
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
		projection        = Perspective_Projection{fov_y = linalg.to_radians(f32(60))},
		near              = 0.1,
		far               = 100.0,
	}
	camera_update_vectors(&c)
	return c
}

camera_update_vectors :: proc(camera: ^Camera) {
	yaw_r := linalg.to_radians(camera.yaw)
	pitch_r := linalg.to_radians(camera.pitch)

	front := Vec3 {
		linalg.cos(yaw_r) * linalg.cos(pitch_r),
		linalg.sin(pitch_r),
		linalg.sin(yaw_r) * linalg.cos(pitch_r),
	}
	camera.front = linalg.normalize(front)

	camera.right = linalg.normalize(linalg.cross(camera.front, camera.world_up))
	camera.up = linalg.normalize(linalg.cross(camera.right, camera.front))
}

camera_get_view_matrix :: proc(c: Camera) -> Mat4x4 {
	return linalg.matrix4_look_at_f32(c.position, c.position + c.front, c.up)
}

camera_get_projection_matrix :: proc(c: Camera, aspect: f32) -> Mat4x4 {
	switch p in c.projection {
	case Perspective_Projection:
		return matrix4_perspective_z0_f32(p.fov_y, aspect, c.near, c.far)
	case Ortho_Projection:
		left, right, bottom, top := ortho_extents_from_scaling_mode(p.scaling_mode, aspect)
		return matrix4_ortho3d_z0_f32(left, right, bottom, top, c.near, c.far)
	}
	return {}
}

// Unprojects a screen-space mouse position into a world-space ray.
// mouse_pos and viewport_size are both in pixels (mouse_pos: top-left origin).
screen_to_world_ray :: proc(camera: Camera, mouse_pos: Vec2, viewport_size: Vec2) -> (origin: Vec3, dir: Vec3) {
	ndc := Vec3{mouse_pos.x / viewport_size.x, mouse_pos.y / viewport_size.y, 1}
	ndc *= 2
	ndc -= 1
	ndc.z = 1 // far plane, in Vulkan's [0,1] depth range

	aspect := viewport_size.x / viewport_size.y
	inverse_proj := linalg.inverse(camera_get_projection_matrix(camera, aspect))
	inverse_view := linalg.inverse(camera_get_view_matrix(camera))

	clip := Vec4{ndc.x, ndc.y, ndc.z, 1}
	view_pos := inverse_proj * clip
	view_pos.xyz /= view_pos.w // undo the perspective divide

	world_pos := (inverse_view * Vec4{view_pos.x, view_pos.y, view_pos.z, 1}).xyz

	origin = camera.position
	dir = linalg.normalize(world_pos - origin)
	return
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
	if p, ok := &c.projection.(Perspective_Projection); ok {
		p.fov_y = clamp(p.fov_y - linalg.to_radians(y_offset), linalg.to_radians(f32(1)), linalg.to_radians(f32(90)))
	}
}


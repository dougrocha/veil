package graphics

import "core:math"
import "core:math/linalg"

GIZMO_SCREEN_SCALE :: 0.15
GIZMO_HEAD_LENGTH :: 0.18
GIZMO_HEAD_WIDTH :: 0.08
GIZMO_END_ON_THRESHOLD :: 0.94
GIZMO_HIT_RADIUS_PX :: 9.0
GIZMO_RING_SEGMENTS :: 48
GIZMO_RING_SCALE :: 0.9

GizmoMode :: enum {
	Translate,
	Rotate,
}

GizmoSpace :: enum {
	World,
	Local,
}

GizmoAxis :: enum {
	None,
	X,
	Y,
	Z,
}

GIZMO_AXES :: [3]GizmoAxis{.X, .Y, .Z}

gizmo_axis_direction :: proc(transform: Transform, axis: GizmoAxis) -> Vec3 {
	switch axis {
	case .X:
		return transform_right(transform)
	case .Y:
		return transform_up(transform)
	case .Z:
		return -transform_forward(transform)
	case .None:
		return {}
	}
	return {}
}

gizmo_translation_axis_direction :: proc(transform: Transform, axis: GizmoAxis, space: GizmoSpace) -> Vec3 {
	if space == .Local do return gizmo_axis_direction(transform, axis)
	switch axis {
	case .X:
		return {1, 0, 0}
	case .Y:
		return {0, 1, 0}
	case .Z:
		return {0, 0, 1}
	case .None:
		return {}
	}
	return {}
}

gizmo_axis_color :: proc(axis: GizmoAxis, active: bool) -> Vec4 {
	if active do return {1, 1, 0.3, 1}
	switch axis {
	case .X:
		return {1, 0.15, 0.15, 1}
	case .Y:
		return {0.2, 1, 0.2, 1}
	case .Z:
		return {0.2, 0.4, 1, 1}
	case .None:
		return {}
	}
	return {}
}

gizmo_length :: proc(cam: Camera, origin: Vec3) -> f32 {
	depth := linalg.dot(origin - cam.position, cam.front)
	return max(depth, cam.near) * f32(GIZMO_SCREEN_SCALE)
}

gizmo_rotation_radius :: proc(cam: Camera, transform: Transform, bounds: BoundingSphere) -> f32 {
	depth := max(linalg.dot(transform.translation - cam.position, cam.front), cam.near)
	scale := transform.scale
	max_scale := max(math.abs(scale.x), math.abs(scale.y), math.abs(scale.z))
	model_reach := (bounds.radius + linalg.length(bounds.center)) * max_scale
	// Keep a small screen-space gap while keeping small models' rings close.
	return min(
		gizmo_length(cam, transform.translation) * f32(GIZMO_RING_SCALE),
		max(model_reach + depth * 0.012, depth * 0.035),
	)
}

gizmo_project :: proc(cam: Camera, point: Vec3, viewport: Vec2) -> (Vec2, bool) {
	clip :=
		camera_get_projection_matrix(cam, viewport.x / viewport.y) *
		camera_get_view_matrix(cam) *
		Vec4{point.x, point.y, point.z, 1}
	if clip.w <= 0 || clip.z < 0 do return {}, false
	return ndc_to_screen(clip.xy / clip.w, viewport), true
}

gizmo_point_segment_distance_sq :: proc(point, a, b: Vec2) -> f32 {
	ab := b - a
	length_sq := linalg.dot(ab, ab)
	if length_sq < 1e-6 do return linalg.dot(point - a, point - a)
	t := math.clamp(linalg.dot(point - a, ab) / length_sq, 0, 1)
	delta := point - (a + ab * t)
	return linalg.dot(delta, delta)
}

// Parameter of the closest point on an axis line to the mouse ray. Using
// the same fixed line throughout a drag avoids accumulating mouse deltas.
gizmo_drag_parameter :: proc(
	cam: Camera,
	axis_origin, axis_direction: Vec3,
	mouse_pos, viewport: Vec2,
) -> (
	f32,
	bool,
) {
	if viewport.x <= 0 || viewport.y <= 0 do return 0, false
	ray_origin, ray_dir := screen_to_world_ray(cam, mouse_pos, viewport)
	axis_ray_dot := linalg.dot(axis_direction, ray_dir)
	denominator := 1 - axis_ray_dot * axis_ray_dot
	// A nearly end-on axis has no stable screen-space movement direction.
	if denominator < 0.01 do return 0, false
	from_axis := ray_origin - axis_origin
	parameter := (linalg.dot(axis_direction, from_axis) - axis_ray_dot * linalg.dot(ray_dir, from_axis)) / denominator
	return parameter, true
}

gizmo_ring_point :: proc(transform: Transform, axis: GizmoAxis, radius, angle: f32) -> Vec3 {
	normal := gizmo_axis_direction(transform, axis)
	first: Vec3
	switch axis {
	case .X:
		first = transform_up(transform)
	case .Y:
		first = -transform_forward(transform)
	case .Z:
		first = transform_right(transform)
	case .None:
		return transform.translation
	}
	second := linalg.cross(normal, first)
	return transform.translation + radius * (first * math.cos(angle) + second * math.sin(angle))
}

// Clip a ring segment to the camera-facing half. When viewed face-on there
// is no geometric near side, so use screen up to keep a stable half-ring.
gizmo_visible_ring_segment :: proc(
	cam: Camera,
	transform: Transform,
	axis: GizmoAxis,
	from, to: Vec3,
) -> (
	Vec3,
	Vec3,
	bool,
) {
	view_dir := linalg.normalize(cam.position - transform.translation)
	normal := gizmo_axis_direction(transform, axis)
	front_dir := view_dir - normal * linalg.dot(view_dir, normal)
	if linalg.dot(front_dir, front_dir) < 0.01 {
		front_dir = cam.up - normal * linalg.dot(cam.up, normal)
		if linalg.dot(front_dir, front_dir) < 0.01 {
			front_dir = cam.right - normal * linalg.dot(cam.right, normal)
		}
	}
	front_dir = linalg.normalize(front_dir)

	from_depth := linalg.dot(from - transform.translation, front_dir)
	to_depth := linalg.dot(to - transform.translation, front_dir)
	if from_depth <= 0 && to_depth <= 0 do return {}, {}, false
	if from_depth >= 0 && to_depth >= 0 do return from, to, true

	crossing := from + (to - from) * (from_depth / (from_depth - to_depth))
	if from_depth > 0 do return from, crossing, true
	return crossing, to, true
}

gizmo_pick_rotation :: proc(
	engine: ^Engine,
	transform: Transform,
	bounds: BoundingSphere,
	mouse_pos, viewport: Vec2,
) -> GizmoAxis {
	cam := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	if viewport.x <= 0 || viewport.y <= 0 do return .None
	if linalg.dot(transform.translation - cam.position, cam.front) <= cam.near do return .None
	radius := gizmo_rotation_radius(cam^, transform, bounds)
	best := f32(GIZMO_HIT_RADIUS_PX * GIZMO_HIT_RADIUS_PX)
	result: GizmoAxis = .None
	for axis in GIZMO_AXES {
		for segment in 0 ..< GIZMO_RING_SEGMENTS {
			angle0 := 2 * math.PI * f32(segment) / f32(GIZMO_RING_SEGMENTS)
			angle1 := 2 * math.PI * f32(segment + 1) / f32(GIZMO_RING_SEGMENTS)
			world0 := gizmo_ring_point(transform, axis, radius, angle0)
			world1 := gizmo_ring_point(transform, axis, radius, angle1)
			segment_visible: bool
			world0, world1, segment_visible = gizmo_visible_ring_segment(cam^, transform, axis, world0, world1)
			if !segment_visible do continue
			point0, visible0 := gizmo_project(cam^, world0, viewport)
			point1, visible1 := gizmo_project(cam^, world1, viewport)
			if !visible0 || !visible1 do continue
			distance_sq := gizmo_point_segment_distance_sq(mouse_pos, point0, point1)
			if distance_sq < best {
				best = distance_sq
				result = axis
			}
		}
	}
	return result
}

// The radial direction where the mouse ray meets the selected rotation plane.
gizmo_rotation_radial :: proc(cam: Camera, center, axis: Vec3, mouse_pos, viewport: Vec2) -> (Vec3, bool) {
	if viewport.x <= 0 || viewport.y <= 0 do return {}, false
	ray_origin, ray_dir := screen_to_world_ray(cam, mouse_pos, viewport)
	denominator := linalg.dot(axis, ray_dir)
	if math.abs(denominator) < 0.05 do return {}, false
	distance := linalg.dot(axis, center - ray_origin) / denominator
	if distance <= 0 do return {}, false
	radial := ray_origin + ray_dir * distance - center
	if linalg.dot(radial, radial) < 1e-8 do return {}, false
	return linalg.normalize(radial), true
}

gizmo_draw_rotation_sweep :: proc(engine: ^Engine, center, axis, start_radial: Vec3, radius, angle: f32, color: Vec4) {
	if math.abs(angle) < 1e-4 do return
	steps := max(1, int(math.ceil(math.abs(angle) * f32(GIZMO_RING_SEGMENTS) / (2 * math.PI))))
	side := linalg.cross(axis, start_radial)
	point_at :: proc(center, start, side: Vec3, radius, angle: f32) -> Vec3 {
		return center + radius * (start * math.cos(angle) + side * math.sin(angle))
	}

	fill := Vec4{color.x, color.y, color.z, 0.16}
	previous := point_at(center, start_radial, side, radius, 0)
	for step in 1 ..= steps {
		fraction := f32(step) / f32(steps)
		current := point_at(center, start_radial, side, radius, angle * fraction)
		line_renderer_push_sector_triangle(&engine.line_renderer, center, previous, current, fill)
		previous = current
	}
	line_renderer_push(&engine.line_renderer, center, center + start_radial * radius, color, overlay = true)
	line_renderer_push(&engine.line_renderer, center, previous, color, overlay = true)
}

gizmo_draw_rotation :: proc(
	engine: ^Engine,
	transform: Transform,
	bounds: BoundingSphere,
	active: GizmoAxis = .None,
	dragging := false,
	start_radial: Vec3 = {},
	sweep_angle: f32 = 0,
) {
	cam := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	if linalg.dot(transform.translation - cam.position, cam.front) <= cam.near do return
	radius := gizmo_rotation_radius(cam^, transform, bounds)
	if dragging && active != .None {
		gizmo_draw_rotation_sweep(
			engine,
			transform.translation,
			gizmo_axis_direction(transform, active),
			start_radial,
			radius,
			sweep_angle,
			gizmo_axis_color(active, false),
		)
	}
	for axis in GIZMO_AXES {
		if dragging && axis != active do continue
		color := gizmo_axis_color(axis, false)
		for segment in 0 ..< GIZMO_RING_SEGMENTS {
			angle0 := 2 * math.PI * f32(segment) / f32(GIZMO_RING_SEGMENTS)
			angle1 := 2 * math.PI * f32(segment + 1) / f32(GIZMO_RING_SEGMENTS)
			point0 := gizmo_ring_point(transform, axis, radius, angle0)
			point1 := gizmo_ring_point(transform, axis, radius, angle1)
			if !dragging || axis != active {
				visible: bool
				point0, point1, visible = gizmo_visible_ring_segment(cam^, transform, axis, point0, point1)
				if !visible do continue
			}
			line_renderer_push(&engine.line_renderer, point0, point1, color, overlay = true)
		}
	}
}

gizmo_pick_translation :: proc(
	engine: ^Engine,
	transform: Transform,
	mouse_pos, viewport: Vec2,
	space: GizmoSpace = .World,
) -> GizmoAxis {
	cam := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	if viewport.x <= 0 || viewport.y <= 0 do return .None
	if linalg.dot(transform.translation - cam.position, cam.front) <= cam.near do return .None
	length := gizmo_length(cam^, transform.translation)
	origin_px, visible := gizmo_project(cam^, transform.translation, viewport)
	if !visible do return .None

	best := f32(GIZMO_HIT_RADIUS_PX * GIZMO_HIT_RADIUS_PX)
	result: GizmoAxis = .None
	for axis in GIZMO_AXES {
		tip := transform.translation + gizmo_translation_axis_direction(transform, axis, space) * length
		tip_px, tip_visible := gizmo_project(cam^, tip, viewport)
		if !tip_visible do continue
		distance_sq := gizmo_point_segment_distance_sq(mouse_pos, origin_px, tip_px)
		if distance_sq < best {
			best = distance_sq
			result = axis
		}
	}
	return result
}

gizmo_draw_translation :: proc(
	engine: ^Engine,
	transform: Transform,
	active: GizmoAxis = .None,
	dragging := false,
	space: GizmoSpace = .World,
) {
	cam := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	origin := transform.translation
	length := gizmo_length(cam^, origin)
	if linalg.dot(origin - cam.position, cam.front) <= cam.near do return
	if dragging && active != .None {
		direction := gizmo_translation_axis_direction(transform, active, space)
		color := gizmo_axis_color(active, false)
		guide_color := Vec4{color.x * 0.35, color.y * 0.35, color.z * 0.35, 1}
		extent := max(cam.far, length * 20)
		line_renderer_push(
			&engine.line_renderer,
			origin - direction * extent,
			origin + direction * extent,
			guide_color,
			overlay = true,
		)
	}

	for axis in GIZMO_AXES {
		if dragging && axis != active do continue
		direction := gizmo_translation_axis_direction(transform, axis, space)
		color := gizmo_axis_color(axis, false)
		tip := origin + direction * length
		line_renderer_push(&engine.line_renderer, origin, tip, color, overlay = true)

		view_dir := linalg.normalize(cam.position - tip)
		side := linalg.cross(direction, view_dir)
		if linalg.dot(side, side) < 1e-6 do side = cam.right
		side = linalg.normalize(side)

		if math.abs(linalg.dot(direction, view_dir)) >= GIZMO_END_ON_THRESHOLD {
			radius := length * f32(GIZMO_HEAD_WIDTH)
			right := cam.right * radius
			up := cam.up * radius
			line_renderer_push(&engine.line_renderer, tip + right, tip + up, color, overlay = true)
			line_renderer_push(&engine.line_renderer, tip + up, tip - right, color, overlay = true)
			line_renderer_push(&engine.line_renderer, tip - right, tip - up, color, overlay = true)
			line_renderer_push(&engine.line_renderer, tip - up, tip + right, color, overlay = true)
		} else {
			base := tip - direction * length * f32(GIZMO_HEAD_LENGTH)
			wing := side * length * f32(GIZMO_HEAD_WIDTH)
			line_renderer_push(&engine.line_renderer, tip, base + wing, color, overlay = true)
			line_renderer_push(&engine.line_renderer, tip, base - wing, color, overlay = true)
		}
	}
}

// Editor state for manipulating the selected instance. The zero value is translate mode in
// world space with no active axis.
GizmoController :: struct {
	mode:                                    GizmoMode,
	space:                                   GizmoSpace, // translate only
	active_axis:                             GizmoAxis,
	dragging:                                bool,

	// Drag state, only meaningful while dragging.
	drag_origin, drag_direction:             Vec3,
	drag_start_parameter:                    f32, // translate
	drag_start_radial, drag_previous_radial: Vec3, // rotate
	drag_sweep_angle:                        f32, // rotate
}

gizmo_set_mode :: proc(gc: ^GizmoController, mode: GizmoMode) {
	gc.dragging = false
	gc.active_axis = .None
	gc.mode = mode
}

// Toggles world/local translation. Does nothing in rotate mode.
gizmo_toggle_space :: proc(gc: ^GizmoController) {
	if gc.mode != .Translate do return
	gc.dragging = false
	gc.active_axis = .None
	gc.space = .Local if gc.space == .World else .World
}

// Stops an in-progress drag, leaving the highlighted axis as is.
gizmo_cancel :: proc(gc: ^GizmoController) {
	gc.dragging = false
}

// Picks an axis of the selected instance's gizmo and starts dragging it. Returns false when
// nothing was hit (or nothing is selected), so the caller can fall back to selecting an object.
gizmo_mouse_down :: proc(gc: ^GizmoController, engine: ^Engine, cam: Camera, mouse_pos, viewport: Vec2) -> bool {
	axis: GizmoAxis = .None
	if engine.scene.selected_instance != INVALID_INSTANCE {
		selected := instance_get(engine, engine.scene.selected_instance)
		if gc.mode == .Translate {
			axis = gizmo_pick_translation(engine, selected.transform, mouse_pos, viewport, gc.space)
		} else {
			model := pool_get(&engine.model_system.models, selected.model)
			axis = gizmo_pick_rotation(engine, selected.transform, model.bounds, mouse_pos, viewport)
		}
	}

	if axis == .None {
		gc.dragging = false
		gc.active_axis = .None
		return false
	}

	gc.active_axis = axis
	selected := instance_get(engine, engine.scene.selected_instance)
	gc.drag_origin = selected.transform.translation
	if gc.mode == .Translate {
		gc.drag_direction = gizmo_translation_axis_direction(selected.transform, axis, gc.space)
		gc.drag_start_parameter, gc.dragging = gizmo_drag_parameter(
			cam,
			gc.drag_origin,
			gc.drag_direction,
			mouse_pos,
			viewport,
		)
	} else {
		gc.drag_direction = gizmo_axis_direction(selected.transform, axis)
		gc.drag_previous_radial, gc.dragging = gizmo_rotation_radial(
			cam,
			gc.drag_origin,
			gc.drag_direction,
			mouse_pos,
			viewport,
		)
		if gc.dragging {
			gc.drag_start_radial = gc.drag_previous_radial
			gc.drag_sweep_angle = 0
		}
	}
	return true
}

// Applies an in-progress drag to the selected instance. Does nothing when not dragging.
gizmo_mouse_move :: proc(gc: ^GizmoController, engine: ^Engine, cam: Camera, mouse_pos, viewport: Vec2) {
	if !gc.dragging do return
	selected := instance_get(engine, engine.scene.selected_instance)

	if gc.mode == .Translate {
		parameter, ok := gizmo_drag_parameter(cam, gc.drag_origin, gc.drag_direction, mouse_pos, viewport)
		if ok do selected.transform.translation = gc.drag_origin + gc.drag_direction * (parameter - gc.drag_start_parameter)
		return
	}

	radial, ok := gizmo_rotation_radial(cam, gc.drag_origin, gc.drag_direction, mouse_pos, viewport)
	if !ok do return
	angle := math.atan2(
		linalg.dot(gc.drag_direction, linalg.cross(gc.drag_previous_radial, radial)),
		linalg.dot(gc.drag_previous_radial, radial),
	)
	step := linalg.quaternion_angle_axis_f32(angle, gc.drag_direction)
	selected.transform.rotation = linalg.normalize(step * selected.transform.rotation)
	gc.drag_sweep_angle += angle
	if gc.drag_sweep_angle >= 2 * math.PI do gc.drag_sweep_angle -= 2 * math.PI
	if gc.drag_sweep_angle <= -2 * math.PI do gc.drag_sweep_angle += 2 * math.PI
	gc.drag_previous_radial = radial
}

gizmo_mouse_up :: proc(gc: ^GizmoController) {
	gc.dragging = false
}

// Queues the gizmo for the selected instance into this frame's debug lines. No-op without a selection.
gizmo_draw :: proc(gc: ^GizmoController, engine: ^Engine) {
	if engine.scene.selected_instance == INVALID_INSTANCE do return
	selected := instance_get(engine, engine.scene.selected_instance)
	if gc.mode == .Translate {
		gizmo_draw_translation(engine, selected.transform, gc.active_axis, gc.dragging, gc.space)
	} else {
		model := pool_get(&engine.model_system.models, selected.model)
		gizmo_draw_rotation(
			engine,
			selected.transform,
			model.bounds,
			gc.active_axis,
			gc.dragging,
			gc.drag_start_radial,
			gc.drag_sweep_angle,
		)
	}
}

package graphics

import "core:math"
import "core:math/linalg"

// Draws an icon for every light, in the light's color: point = small marker + range circles,
// spot = marker + cone to range, directional = arrow from the camera's view center. Lines are
// depth tested, so they hide behind geometry. Toggled by debug_settings.show_lights.
debug_lights_draw :: proc(engine: ^Engine, scene: ^Scene) {
	if !engine.debug_settings.show_lights do return
	lr := &engine.line_renderer

	for light in scene.point_lights[:scene.point_light_count] {
		color := Vec4{light.color.r, light.color.g, light.color.b, 1}
		debug_marker(lr, light.pos, 0.1, color)
		dim := color * {1, 1, 1, 0.35}
		debug_circle(lr, light.pos, {1, 0, 0}, {0, 0, 1}, light.range, dim)
		debug_circle(lr, light.pos, {1, 0, 0}, {0, 1, 0}, light.range, dim)
		debug_circle(lr, light.pos, {0, 1, 0}, {0, 0, 1}, light.range, dim)
	}

	for light in scene.spot_lights[:scene.spot_light_count] {
		color := Vec4{light.color.r, light.color.g, light.color.b, 1}
		debug_marker(lr, light.pos, 0.1, color)
		dir := linalg.normalize(light.direction)
		u, v := debug_basis(dir)
		// outer_cutoff is the cosine of the cone's half angle
		radius := light.range * math.tan(math.acos(clamp(light.outer_cutoff, -1, 1)))
		end := light.pos + dir * light.range
		debug_circle(lr, end, u, v, radius, color)
		for i in 0 ..< 4 {
			a := f32(i) * math.PI / 2
			line_renderer_push(lr, light.pos, end + (u * math.cos(a) + v * math.sin(a)) * radius, color)
		}
	}

	cam := camera_system_get_camera(&engine.camera_system, scene.active_camera_name)
	for light in scene.directional_lights[:scene.directional_light_count] {
		color := Vec4{light.color.r, light.color.g, light.color.b, 1}
		dir := linalg.normalize(light.direction)
		start := cam.position + cam.front * 3 - dir
		end := start + dir
		line_renderer_push(lr, start, end, color, overlay = true)
		u, v := debug_basis(dir)
		line_renderer_push(lr, end, end - dir * 0.2 + u * 0.08, color, overlay = true)
		line_renderer_push(lr, end, end - dir * 0.2 - u * 0.08, color, overlay = true)
		line_renderer_push(lr, end, end - dir * 0.2 + v * 0.08, color, overlay = true)
		line_renderer_push(lr, end, end - dir * 0.2 - v * 0.08, color, overlay = true)
	}
}

// Three axis lines through p, drawn on top so a light inside an object stays visible.
@(private = "file")
debug_marker :: proc(lr: ^LineRenderer, p: Vec3, size: f32, color: Vec4) {
	line_renderer_push(lr, p - {size, 0, 0}, p + {size, 0, 0}, color, overlay = true)
	line_renderer_push(lr, p - {0, size, 0}, p + {0, size, 0}, color, overlay = true)
	line_renderer_push(lr, p - {0, 0, size}, p + {0, 0, size}, color, overlay = true)
}

@(private = "file")
debug_circle :: proc(lr: ^LineRenderer, center, u, v: Vec3, radius: f32, color: Vec4) {
	SEGMENTS :: 32
	prev := center + u * radius
	for i in 1 ..= SEGMENTS {
		a := f32(i) / SEGMENTS * 2 * math.PI
		next := center + (u * math.cos(a) + v * math.sin(a)) * radius
		line_renderer_push(lr, prev, next, color)
		prev = next
	}
}

// Two unit vectors perpendicular to dir and to each other.
@(private = "file")
debug_basis :: proc(dir: Vec3) -> (u, v: Vec3) {
	up := Vec3{0, 1, 0} if abs(dir.y) < 0.999 else Vec3{1, 0, 0}
	u = linalg.normalize(linalg.cross(dir, up))
	v = linalg.cross(dir, u)
	return
}

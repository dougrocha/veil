package main

import "core:c"
import gfx "veil:graphics"
import sdl "vendor:sdl3"

// 4K scanned PBR models with their texture sets.
// SDL reports logical window coordinates; picking and the gizmo work in render extent pixels.
mouse_to_pixels :: proc(window: ^sdl.Window, engine: ^gfx.Engine, x, y: f32) -> (pos: gfx.Vec2, ok: bool) {
	window_w, window_h: c.int
	_ = sdl.GetWindowSize(window, &window_w, &window_h)
	viewport := gfx.render_viewport(engine)
	if window_w <= 0 || window_h <= 0 || viewport.x <= 0 || viewport.y <= 0 do return {}, false
	return {x * viewport.x / f32(window_w), y * viewport.y / f32(window_h)}, true
}

process_input :: proc(camera: ^gfx.Camera, dt: f32) {
	keys := sdl.GetKeyboardState(nil)

	if keys[sdl.Scancode.W] do camera_process_keyboard(camera, .Forward, dt)
	if keys[sdl.Scancode.S] do camera_process_keyboard(camera, .Backward, dt)
	if keys[sdl.Scancode.A] do camera_process_keyboard(camera, .Left, dt)
	if keys[sdl.Scancode.D] do camera_process_keyboard(camera, .Right, dt)
	if keys[sdl.Scancode.SPACE] do camera_process_keyboard(camera, .Up, dt)
	if keys[sdl.Scancode.LCTRL] do camera_process_keyboard(camera, .Down, dt)
}

package main

import "core:log"
import "core:time"

import sdl "vendor:sdl3"

import gfx "graphics"

main :: proc() {
	context.logger = log.create_console_logger()
	gfx.g_ctx = context

	ok := sdl.InitSubSystem({.VIDEO})
	if !ok {
		log.errorf("Failed to init")
		return
	}
	defer sdl.Quit()

	app := gfx.App {
		width  = 1280,
		height = 720,
	}

	app.window = sdl.CreateWindow("odin-vulkan", i32(app.width), i32(app.height), {.RESIZABLE, .VULKAN})
	if app.window == nil {
		log.errorf("Failed to create window: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(app.window)

	_ = sdl.SetWindowRelativeMouseMode(app.window, true)

	gfx.load_model(&app.engine)

	// app.engine.vertices = []gfx.Vertex {
	// 	{pos = {-0.5, -0.5, 0.0}, color = {1.0, 1.0, 1.0}, tex_coord = {0.0, 0.0}},
	// 	{pos = {0.5, -0.5, 0.0}, color = {1.0, 1.0, 1.0}, tex_coord = {1.0, 0.0}},
	// 	{pos = {0.5, 0.5, 0.0}, color = {1.0, 1.0, 1.0}, tex_coord = {1.0, 1.0}},
	// 	{pos = {-0.5, 0.5, 0.0}, color = {1.0, 1.0, 1.0}, tex_coord = {0.0, 1.0}},
	// 	{pos = {-0.5, -0.5, -0.5}, color = {1.0, 1.0, 1.0}, tex_coord = {0.0, 0.0}},
	// 	{pos = {0.5, -0.5, -0.5}, color = {1.0, 1.0, 1.0}, tex_coord = {1.0, 0.0}},
	// 	{pos = {0.5, 0.5, -0.5}, color = {1.0, 1.0, 1.0}, tex_coord = {1.0, 1.0}},
	// 	{pos = {-0.5, 0.5, -0.5}, color = {1.0, 1.0, 1.0}, tex_coord = {0.0, 1.0}},
	// }
	// app.engine.indices = []u32{0, 1, 2, 2, 3, 0, 4, 5, 6, 6, 7, 4}

	init_ok := gfx.initialize_vulkan(&app)
	if !init_ok {
		log.errorf("Failed to initialize Vulkan")
		return
	}
	defer gfx.engine_shutdown(&app.engine)

	main_loop: for {
		ev: sdl.Event

		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
			case .MOUSE_MOTION:
				gfx.camera_process_mouse_movement(
					&app.engine.camera,
					ev.motion.xrel,
					-ev.motion.yrel,
				)
			case .MOUSE_WHEEL:
				gfx.camera_process_mouse_scroll(&app.engine.camera, ev.wheel.y)
			case .WINDOW_PIXEL_SIZE_CHANGED:
				app.width = u32(ev.window.data1)
				app.height = u32(ev.window.data2)
				app.engine.require_swapchain_recreate = true
			}
		}

		now := time.now()
		app.engine.delta_time = f32(time.duration_seconds(time.diff(app.engine.last_frame_time, now)))
		app.engine.last_frame_time = now

		process_input(&app.engine)
		gfx.engine_render(&app)
	}
}

process_input :: proc(engine: ^gfx.Engine) {
	keys := sdl.GetKeyboardState(nil)

	if keys[sdl.Scancode.W]     do gfx.camera_process_keyboard(&engine.camera, .Forward,  engine.delta_time)
	if keys[sdl.Scancode.S]     do gfx.camera_process_keyboard(&engine.camera, .Backward, engine.delta_time)
	if keys[sdl.Scancode.A]     do gfx.camera_process_keyboard(&engine.camera, .Left,     engine.delta_time)
	if keys[sdl.Scancode.D]     do gfx.camera_process_keyboard(&engine.camera, .Right,    engine.delta_time)
	if keys[sdl.Scancode.SPACE] do gfx.camera_process_keyboard(&engine.camera, .Up,       engine.delta_time)
	if keys[sdl.Scancode.LCTRL] do gfx.camera_process_keyboard(&engine.camera, .Down,     engine.delta_time)
}


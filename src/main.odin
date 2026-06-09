package main

import "core:log"

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

	if !gfx.initialize_vulkan(&app) {
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
				if ev.key.key == sdl.K_ESCAPE {
					break main_loop
				}
			case .WINDOW_PIXEL_SIZE_CHANGED:
				app.width = u32(ev.window.data1)
				app.height = u32(ev.window.data2)
				app.engine.require_swapchain_recreate = true
			}
		}

		gfx.engine_render(&app)
	}
}


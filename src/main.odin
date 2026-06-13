package main

import "core:log"
import "core:math/linalg"
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


	init_ok := gfx.initialize_vulkan(&app)
	if !init_ok {
		log.errorf("Failed to initialize Vulkan")
		return
	}
	defer gfx.engine_shutdown(&app.engine)

	devin_texture := gfx.load_texture(&app.engine, "assets/textures/devin.png")
	plane_model := gfx.create_cube(&app.engine, "devin", devin_texture)
	gfx.spawn_model(&app.engine, plane_model, gfx.transform_create())


	// viking_texture := gfx.load_texture(&app.engine, "assets/textures/viking_room.png")
	// viking_model := gfx.load_model(&app.engine, "assets/models/viking_room.obj", viking_texture)
	// correction := linalg.quaternion_angle_axis_f32(linalg.to_radians(f32(-90)), gfx.Vec3{1, 0, 0})
	// // TODO: make the api so I can call draw on a Model Handle
	// gfx.spawn_model(
	// 	&app.engine,
	// 	viking_model,
	// 	gfx.Transform{translation = {0, 0, 0}, rotation = correction, scale = {1, 1, 1}},
	// )


	main_loop: for {
		ev: sdl.Event

		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
			case .MOUSE_MOTION:
				gfx.camera_process_mouse_movement(&app.engine.camera, ev.motion.xrel, -ev.motion.yrel)
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

		app.engine.fps_frame_count += 1
		app.engine.fps_timer += app.engine.delta_time
		if app.engine.fps_timer >= 1.0 {
			log.infof("FPS: %d", app.engine.fps_frame_count)
			app.engine.fps_frame_count = 0
			app.engine.fps_timer = 0
		}

		process_input(&app.engine)
		gfx.engine_render(&app)
	}
}

process_input :: proc(engine: ^gfx.Engine) {
	keys := sdl.GetKeyboardState(nil)

	if keys[sdl.Scancode.W] do gfx.camera_process_keyboard(&engine.camera, .Forward, engine.delta_time)
	if keys[sdl.Scancode.S] do gfx.camera_process_keyboard(&engine.camera, .Backward, engine.delta_time)
	if keys[sdl.Scancode.A] do gfx.camera_process_keyboard(&engine.camera, .Left, engine.delta_time)
	if keys[sdl.Scancode.D] do gfx.camera_process_keyboard(&engine.camera, .Right, engine.delta_time)
	if keys[sdl.Scancode.SPACE] do gfx.camera_process_keyboard(&engine.camera, .Up, engine.delta_time)
	if keys[sdl.Scancode.LCTRL] do gfx.camera_process_keyboard(&engine.camera, .Down, engine.delta_time)
}


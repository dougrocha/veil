package main

import "core:c"
import "core:log"
import "core:math/linalg"
import "core:time"

import sdl "vendor:sdl3"

import gfx "graphics"

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

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

	app.window = sdl.CreateWindow("veil", i32(app.width), i32(app.height), {.VULKAN, .RESIZABLE})
	if app.window == nil {
		log.errorf("Failed to create window: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(app.window)

	mouse_captured := true
	_ = sdl.SetWindowRelativeMouseMode(app.window, true)

	init_ok := gfx.engine_create(&app.engine, app.window, app.width, app.height)
	if !init_ok {
		log.errorf("Failed to initialize Vulkan")
		return
	}
	defer gfx.engine_destroy(&app.engine)

	ui_font, font_ok := gfx.font_load_default_system(&app.engine, 20)
	assert(font_ok, "no default system font found")
	// Declared after engine_destroy's defer, so it runs first.
	defer gfx.font_destroy(&app.engine, &ui_font)

	app.last_frame_time = time.now()

	load_bloom_test(&app.engine)

	space_skybox_tex := gfx.texture_load_cubemap(&app.engine, "assets/textures/StandardCubeMap.png")
	gfx.set_skybox_texture(&app.engine, space_skybox_tex)

	gizmo: gfx.GizmoController
	show_stats := true
	main_loop: for {
		// Game-side temp allocations live for one loop iteration; the engine resets its own
		// frame arena inside engine_render.
		defer free_all(context.temp_allocator)

		ev: sdl.Event
		active_cam := gfx.camera_system_get_camera(&app.engine.camera_system, app.engine.scene.active_camera_name)

		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				#partial switch ev.key.scancode {
				case .ESCAPE:
					gfx.gizmo_cancel(&gizmo)
					mouse_captured = !mouse_captured
					_ = sdl.SetWindowRelativeMouseMode(app.window, mouse_captured)
				case .G:
					gfx.gizmo_set_mode(&gizmo, .Translate)
				case .R:
					gfx.gizmo_set_mode(&gizmo, .Rotate)
				case .L:
					gfx.gizmo_toggle_space(&gizmo)
				case ._1:
					active_cam.near = 0.1
					active_cam.far = 100.0
				case ._2:
					active_cam.near = 100.0
					active_cam.far = 200.0
				case ._3:
					active_cam.near = 200.0
					active_cam.far = 500.0
				case ._4:
					active_cam.near = 500.0
					active_cam.far = 5000.0
				case .F3:
					show_stats = !show_stats
				case .C:
					app.engine.debug_settings.show_cascades = 1 - app.engine.debug_settings.show_cascades
				case .V:
					app.engine.debug_settings.disable_shadows = 1 - app.engine.debug_settings.disable_shadows
					log.infof("shadows disabled: %v", app.engine.debug_settings.disable_shadows != 0)
				case .P:
					app.engine.debug_settings.light_mask ~= u32(gfx.LightMask.Point)
					log.infof("light mask: 0b%b", app.engine.debug_settings.light_mask)
				case .K:
					app.engine.debug_settings.light_mask ~= u32(gfx.LightMask.Spot)
					log.infof("light mask: 0b%b", app.engine.debug_settings.light_mask)
				case .J:
					app.engine.debug_settings.light_mask ~= u32(gfx.LightMask.Directional)
					log.infof("light mask: 0b%b", app.engine.debug_settings.light_mask)
				case .LEFT:
					gfx.post_control_cycle(&app.engine, -1)
				case .RIGHT:
					gfx.post_control_cycle(&app.engine, 1)
				case .UP:
					gfx.post_control_step(&app.engine, 1)
				case .DOWN:
					gfx.post_control_step(&app.engine, -1)
				case .X:
					app.engine.debug_settings.particles = !app.engine.debug_settings.particles
					log.infof("particles: %v", app.engine.debug_settings.particles)
				case .O:
					switch _ in active_cam.projection {
					case gfx.Perspective_Projection:
						active_cam.projection = gfx.Ortho_Projection {
							scaling_mode = gfx.Fixed_Vertical{height = 10},
						}
					case gfx.Ortho_Projection:
						active_cam.projection = gfx.Perspective_Projection {
							fov_y = linalg.to_radians(f32(60)),
						}
					}
				case .T:
					if active_cam.control_type == .Orbit {
						active_cam.control_type = .Free
					} else {
						target := gfx.Vec3{0, 0, 0}
						if gfx.selected_instance(&app.engine.scene) != gfx.INVALID_INSTANCE {
							selected := gfx.instance_get(&app.engine, gfx.selected_instance(&app.engine.scene))
							target = selected.transform.translation
						}
						gfx.camera_orbit_begin(active_cam, target)
					}
				}
			case .MOUSE_MOTION:
				if mouse_captured {
					gfx.camera_process_mouse_movement(active_cam, ev.motion.xrel, -ev.motion.yrel)
				} else if gizmo.dragging {
					mouse_pos, viewport_size := mouse_to_pixels(app.window, ev.motion.x, ev.motion.y)
					gfx.gizmo_mouse_move(&gizmo, &app.engine, active_cam^, mouse_pos, viewport_size)
				}
			case .MOUSE_BUTTON_DOWN:
				if !mouse_captured && ev.button.button == sdl.BUTTON_LEFT {
					mouse_pos, viewport_size := mouse_to_pixels(app.window, ev.button.x, ev.button.y)
					if viewport_size.x <= 0 || viewport_size.y <= 0 do continue
					if !gfx.gizmo_mouse_down(&gizmo, &app.engine, active_cam^, mouse_pos, viewport_size) {
						hit := gfx.pick(&app.engine, mouse_pos)
						app.engine.scene.selection = nil
						if hit != gfx.INVALID_INSTANCE {
							app.engine.scene.selection = hit
							instance := gfx.instance_get(&app.engine, hit)
							model := gfx.pool_get(&app.engine.model_system.models, instance.model)
							log.infof("selected: %v", model.name)
						}
					}
				}
			case .MOUSE_BUTTON_UP:
				if ev.button.button == sdl.BUTTON_LEFT do gfx.gizmo_mouse_up(&gizmo)
			case .MOUSE_WHEEL:
				gfx.camera_process_mouse_scroll(active_cam, ev.wheel.y)
			case .WINDOW_PIXEL_SIZE_CHANGED:
				app.width = u32(ev.window.data1)
				app.height = u32(ev.window.data2)
				app.engine.swapchain.require_recreate = true
			}
		}

		now := time.now()
		delta_time := f32(time.duration_seconds(time.diff(app.last_frame_time, now)))
		app.last_frame_time = now

		process_input(active_cam, delta_time)

		gfx.gizmo_draw(&gizmo, &app.engine)

		// Debug texture views are queued per frame like UI text. Example: show the selection's
		// textures (material maps, or a light's shadow maps) as a column of 128px tiles.
		//
		// app.engine.scene.selection = gfx.DirectionalLightIndex(0)
		// for tex, i in gfx.entity_textures(&app.engine, app.engine.scene.selection) {
		// 	rect := gfx.Rect2D {
		// 		offset = {10, 50 + i32(i) * 136},
		// 		extent = {128, 128},
		// 	}
		// 	gfx.debug_view_draw(&app.engine, tex.view, rect)
		// }
		//
		// Any 2D texture handle works too (not cubemaps like the skybox):
		// gfx.debug_view_texture(&app.engine, some_texture, {offset = {10, 50}, extent = {256, 256}})

		if show_stats do gfx.stats_draw(&app.engine, &ui_font, 10, 24, 24)

		gfx.engine_render(&app.engine, app.width, app.height, delta_time)
	}
}
// 4K scanned PBR models with their texture sets.
// SDL reports logical window coordinates; rendering and picking use pixels.
mouse_to_pixels :: proc(window: ^sdl.Window, x, y: f32) -> (gfx.Vec2, gfx.Vec2) {
	window_w, window_h: c.int
	pixel_w, pixel_h: c.int
	_ = sdl.GetWindowSize(window, &window_w, &window_h)
	_ = sdl.GetWindowSizeInPixels(window, &pixel_w, &pixel_h)
	viewport := gfx.Vec2{f32(pixel_w), f32(pixel_h)}
	if window_w <= 0 || window_h <= 0 do return {}, viewport
	return {x * viewport.x / f32(window_w), y * viewport.y / f32(window_h)}, viewport
}

process_input :: proc(camera: ^gfx.Camera, dt: f32) {
	keys := sdl.GetKeyboardState(nil)

	if keys[sdl.Scancode.W] do gfx.camera_process_keyboard(camera, .Forward, dt)
	if keys[sdl.Scancode.S] do gfx.camera_process_keyboard(camera, .Backward, dt)
	if keys[sdl.Scancode.A] do gfx.camera_process_keyboard(camera, .Left, dt)
	if keys[sdl.Scancode.D] do gfx.camera_process_keyboard(camera, .Right, dt)
	if keys[sdl.Scancode.SPACE] do gfx.camera_process_keyboard(camera, .Up, dt)
	if keys[sdl.Scancode.LCTRL] do gfx.camera_process_keyboard(camera, .Down, dt)
}

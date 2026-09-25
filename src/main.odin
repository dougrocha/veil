package main

import "core:c"
import "core:fmt"
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

	window_flags := gfx.window_backend_flags()
	window_flags += {.RESIZABLE}
	app.window = sdl.CreateWindow("veil", i32(app.width), i32(app.height), window_flags)
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

	ui_font, font_ok := gfx.font_load_default_system(&app.engine, 32)
	assert(font_ok, "no default system font found")
	// Declared after engine_destroy's defer, so it runs first.
	defer gfx.font_destroy(&app.engine, &ui_font)

	app.last_frame_time = time.now()

	load_sponza(&app.engine)

	space_skybox_tex := gfx.texture_load_cubemap(&app.engine, "assets/textures/StandardCubeMap.png")
	gfx.set_skybox_texture(&app.engine, space_skybox_tex)

	gizmo: gfx.GizmoController
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
						if app.engine.scene.selected_instance != gfx.INVALID_INSTANCE {
							selected := gfx.instance_get(&app.engine, app.engine.scene.selected_instance)
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
						app.engine.scene.selected_instance = hit
						if hit != gfx.INVALID_INSTANCE {
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

		app.fps_frame_count += 1
		app.fps_timer += delta_time
		process_input(active_cam, delta_time)
		if app.fps_timer >= 1.0 {
			app.avg_fps = app.fps_frame_count
			log.infof("FPS: %d, models drawn: %d", app.fps_frame_count, app.engine.drawn_instance_count)
			log.infof("(%v) Camera position: %v", app.engine.scene.active_camera_name, active_cam.position)
			app.fps_frame_count = 0
			app.fps_timer = 0
		}

		gfx.gizmo_draw(&gizmo, &app.engine)


		fps_text := fmt.tprintf("%d Avg FPS", app.avg_fps)
		gfx.ui_draw_text(&app.engine, &ui_font, fps_text, 10, 30, {0, 0, 0, 255})

		gfx.engine_render(&app, delta_time)
	}
}

// 4K scanned PBR models with their texture sets.
load_pbr_showcase :: proc(engine: ^gfx.Engine) {
	wood_gate_mat := gfx.material_create(
		engine,
		"wood_gate",
		base_color_texture = gfx.texture_load(engine, "assets/textures/wooden_gate_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(engine, "assets/textures/wooden_gate_nor_gl_4k.jpg", false),
		metallic_roughness_texture = gfx.texture_load(engine, "assets/textures/wooden_gate_arm_4k.jpg", false),
		occlusion_texture = gfx.texture_load(engine, "assets/textures/wooden_gate_ao_4k.png", false),
	)
	wood_gate := gfx.model_load(engine, "assets/models/wooden_gate_4k.gltf", wood_gate_mat)
	gfx.instance_spawn(engine, wood_gate, gfx.transform_create(translation = {0, 1, -2}))

	lion_head_mat := gfx.material_create(
		engine,
		"lion_head",
		base_color_texture = gfx.texture_load(engine, "assets/models/textures/lion_head_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(engine, "assets/models/textures/lion_head_nor_gl_4k.jpg", false),
		metallic_roughness_texture = gfx.texture_load(engine, "assets/models/textures/lion_head_arm_4k.jpg", false),
		occlusion_texture = gfx.texture_load(engine, "assets/models/textures/lion_head_arm_4k.jpg", false),
	)
	lion_head := gfx.model_load(engine, "assets/models/lion_head_4k.gltf", lion_head_mat)
	gfx.instance_spawn(engine, lion_head, gfx.transform_create(translation = {0, 1.5, 0}))

	boulder_mat := gfx.material_create(
		engine,
		"boulder",
		base_color_texture = gfx.texture_load(engine, "assets/models/textures/namaqualand_boulder_02_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(
			engine,
			"assets/models/textures/namaqualand_boulder_02_nor_gl_4k.jpg",
			false,
		),
		metallic_roughness_texture = gfx.texture_load(
			engine,
			"assets/models/textures/namaqualand_boulder_02_arm_4k.jpg",
			false,
		),
		occlusion_texture = gfx.texture_load(
			engine,
			"assets/models/textures/namaqualand_boulder_02_arm_4k.jpg",
			false,
		),
	)
	boulder := gfx.model_load(engine, "assets/models/namaqualand_boulder_02_4k.gltf", boulder_mat)
	gfx.instance_spawn(engine, boulder, gfx.transform_create(translation = {3, 0.06, 2}))

	duck_mat := gfx.material_create(
		engine,
		"duck",
		base_color_texture = gfx.texture_load(engine, "assets/models/textures/rubber_duck_toy_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(engine, "assets/models/textures/rubber_duck_toy_nor_gl_4k.jpg", false),
		metallic_roughness_texture = gfx.texture_load(
			engine,
			"assets/models/textures/rubber_duck_toy_arm_4k.jpg",
			false,
		),
		occlusion_texture = gfx.texture_load(engine, "assets/models/textures/rubber_duck_toy_arm_4k.jpg", false),
	)
	duck := gfx.model_load(engine, "assets/models/rubber_duck_toy_4k.gltf", duck_mat)
	gfx.instance_spawn(engine, duck, gfx.transform_create(translation = {-3, 0, 2}))
}

load_sponza :: proc(engine: ^gfx.Engine) {
	sponza := gfx.model_load(engine, "assets/models/sponza-gltf-pbr/sponza.glb")
	gfx.instance_spawn(engine, sponza, gfx.transform_create(translation = {0, 0, 0}, scale = {0.01, 0.01, 0.01}))

	// West end of the atrium, looking down its long (+x) axis.
	engine.camera_system.default_camera = gfx.camera_create({-12, 1.8, 0}, yaw = 0, pitch = 5)

	// No GI, so the arcades rely on ambient to stay readable.
	engine.scene.ambient_light = gfx.AmbientLight {
		color      = {0.6, 0.7, 1.0, 1},
		brightness = 0.3,
	}
	// Steep sun through the open roof, tilted across the short (z) axis so one arcade is lit
	// and the gallery columns cast long shadows on the floor.
	gfx.spawn_directional_light(
		engine,
		gfx.DirectionalLight {
			direction               = linalg.normalize(gfx.Vec3{0.2, -1.0, 0.35}),
			color                   = {1.0, 0.92, 0.8},
			diffuse_intensity       = 1.2,
			specular_intensity      = 0.3,
			// atrium is ~30 units long at 0.01 scale
			shadow_maximum_distance = 40.0,
		},
	)

	// Fire light above the four wall-mounted torch bowls on the inner columns.
	torches := [?]gfx.Vec3{{4.88, 2.4, -2.0}, {-6.19, 2.4, -2.0}, {4.88, 2.4, 1.25}, {-6.19, 2.4, 1.25}}
	for pos in torches {
		gfx.light_spawn_point(
			engine,
			gfx.PointLight {
				pos = pos,
				range = 10.0,
				shadow_near = 0.1,
				color = {1.0, 0.6, 0.3},
				constant = 1,
				linear = 0.22,
				quadratic = 0.2,
				diffuse_intensity = 1.5,
				specular_intensity = 0.5,
			},
		)
	}
}

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

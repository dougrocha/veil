package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
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

	app.last_frame_time = time.now()

	app.engine.camera_system.default_camera = gfx.camera_create({0, 1, 5}, yaw = -90, pitch = 0)

	shiny_mat := gfx.material_create(&app.engine, "shiny_mat", perceptual_roughness = 0.0)
	rough_mat := gfx.material_create(&app.engine, "rough_mat", perceptual_roughness = 1.0)
	shiny_cube := gfx.primitive_cube(&app.engine, "shiny_cube", shiny_mat)
	rough_cube := gfx.primitive_cube(&app.engine, "rough_cube", rough_mat)
	shiny_cube_instance := gfx.instance_spawn(&app.engine, shiny_cube, gfx.transform_create(translation = {-2, 1, 0}))
	rough_cube_instance := gfx.instance_spawn(&app.engine, rough_cube, gfx.transform_create(translation = {2, 1, 0}))

	ground_mat := gfx.material_create(&app.engine, "ground_mat", perceptual_roughness = 0.9)
	ground_plane := gfx.primitive_plane(&app.engine, "ground_plane", ground_mat, half_size = {10, 10})
	gfx.instance_spawn(&app.engine, ground_plane, gfx.transform_create(translation = {0, 0, 0}))

	// center sphere: main shadow caster for the camera-mounted spot light
	matte_mat := gfx.material_create(&app.engine, "matte_mat", perceptual_roughness = 0.5)
	test_sphere := gfx.primitive_sphere(&app.engine, "test_sphere", material = matte_mat)
	gfx.instance_spawn(&app.engine, test_sphere, gfx.transform_create(translation = {0, 1, 0}))

	// back wall: vertical receiver so spot/point shadows are visible without looking at the floor
	back_wall := gfx.primitive_cube(&app.engine, "back_wall", rough_mat)
	gfx.instance_spawn(&app.engine, back_wall, gfx.transform_create(translation = {0, 2, -6}, scale = {6, 2, 0.2}))

	// Optional scenes, not loaded by default:
	// load_pbr_showcase(&app.engine)
	// load_sponza(&app.engine)

	space_skybox_tex := gfx.texture_load_cubemap(&app.engine, "assets/textures/StandardCubeMap.png")
	gfx.set_skybox_texture(&app.engine, space_skybox_tex)

	point_light_index := app.engine.scene.point_light_count
	gfx.light_spawn_point(
		&app.engine,
		gfx.PointLight {
			pos = {0, 10, 0},
			range = 20.0,
			shadow_near = 0.1,
			color = {1, 0.2, 0.2},
			constant = 1,
			linear = 0.09,
			quadratic = 0.032,
			diffuse_intensity = 1.0,
			specular_intensity = 0.5,
		},
	)
	gfx.spawn_spot_light(
		&app.engine,
		gfx.SpotLight {
			pos                = {0, 6, 5},
			range              = 20.0,
			shadow_near        = 0.1,
			direction          = {0, -1, -1}, // aimed dead-center at the test sphere
			color              = {1, 1, 1},
			inner_cutoff       = math.cos(math.to_radians(f32(12.5))),
			outer_cutoff       = math.cos(math.to_radians(f32(22.5))),
			constant           = 1,
			linear             = 0.09,
			quadratic          = 0.032,
			diffuse_intensity  = 1.0,
			specular_intensity = 1.0,
		},
	)
	gfx.spawn_directional_light(
		&app.engine,
		gfx.DirectionalLight {
			direction               = linalg.normalize(gfx.Vec3{-1.0, -1.0, 0.5}),
			color                   = {1.0, 0.9, 0.8},
			diffuse_intensity       = 0.3,
			specular_intensity      = 0.2,
			// scene is ~15 units deep; keeps all four cascades over real geometry
			shadow_maximum_distance = 25.0,
		},
	)

	yellow_mat := gfx.material_create(&app.engine, "yellow_mat", base_color = {1, 1, 0, 1})
	light_sphere_model := gfx.primitive_sphere(&app.engine, "light_sphere", material = yellow_mat)
	light_sphere := gfx.instance_spawn(
		&app.engine,
		light_sphere_model,
		gfx.transform_create(scale = {0.2, 0.2, 0.2}),
		casts_shadow = false,
	)

	light_pos := gfx.Vec3{-3, 3, 1}
	app.engine.scene.point_lights[point_light_index].pos = light_pos
	gfx.instance_get(&app.engine, light_sphere).transform.translation = light_pos

	active_gizmo_axis: gfx.GizmoAxis = .None
	gizmo_mode: gfx.GizmoMode = .Translate
	translation_space: gfx.GizmoSpace = .World
	gizmo_dragging := false
	drag_origin: gfx.Vec3
	drag_direction: gfx.Vec3
	drag_start_parameter: f32
	drag_start_radial: gfx.Vec3
	drag_previous_radial: gfx.Vec3
	drag_sweep_angle: f32
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
					gizmo_dragging = false
					mouse_captured = !mouse_captured
					_ = sdl.SetWindowRelativeMouseMode(app.window, mouse_captured)
				case .G:
					gizmo_dragging = false
					active_gizmo_axis = .None
					gizmo_mode = .Translate
				case .R:
					gizmo_dragging = false
					active_gizmo_axis = .None
					gizmo_mode = .Rotate
				case .L:
					if gizmo_mode == .Translate {
						gizmo_dragging = false
						active_gizmo_axis = .None
						translation_space = .Local if translation_space == .World else .World
					}
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
				} else if gizmo_dragging {
					mouse_pos, viewport_size := mouse_to_pixels(app.window, ev.motion.x, ev.motion.y)
					selected := gfx.instance_get(&app.engine, app.engine.scene.selected_instance)
					if gizmo_mode == .Translate {
						parameter, ok := gfx.gizmo_drag_parameter(
							active_cam^,
							drag_origin,
							drag_direction,
							mouse_pos,
							viewport_size,
						)
						if ok do selected.transform.translation = drag_origin + drag_direction * (parameter - drag_start_parameter)
					} else {
						radial, ok := gfx.gizmo_rotation_radial(
							active_cam^,
							drag_origin,
							drag_direction,
							mouse_pos,
							viewport_size,
						)
						if ok {
							angle := math.atan2(
								linalg.dot(drag_direction, linalg.cross(drag_previous_radial, radial)),
								linalg.dot(drag_previous_radial, radial),
							)
							step := linalg.quaternion_angle_axis_f32(angle, drag_direction)
							selected.transform.rotation = linalg.normalize(step * selected.transform.rotation)
							drag_sweep_angle += angle
							if drag_sweep_angle >= 2 * math.PI do drag_sweep_angle -= 2 * math.PI
							if drag_sweep_angle <= -2 * math.PI do drag_sweep_angle += 2 * math.PI
							drag_previous_radial = radial
						}
					}
				}
			case .MOUSE_BUTTON_DOWN:
				if !mouse_captured && ev.button.button == sdl.BUTTON_LEFT {
					mouse_pos, viewport_size := mouse_to_pixels(app.window, ev.button.x, ev.button.y)
					if viewport_size.x <= 0 || viewport_size.y <= 0 do continue
					ray_origin, ray_dir := gfx.screen_to_world_ray(active_cam^, mouse_pos, viewport_size)
					log.infof("mouse_pos: %v, ray_origin: %v, ray_dir: %v", mouse_pos, ray_origin, ray_dir)

					axis: gfx.GizmoAxis = .None
					if app.engine.scene.selected_instance != gfx.INVALID_INSTANCE {
						selected := gfx.instance_get(&app.engine, app.engine.scene.selected_instance)
						if gizmo_mode == .Translate {
							axis = gfx.gizmo_pick_translation(
								&app.engine,
								selected.transform,
								mouse_pos,
								viewport_size,
								translation_space,
							)
						} else {
							model := gfx.pool_get(&app.engine.model_system.models, selected.model)
							axis = gfx.gizmo_pick_rotation(
								&app.engine,
								selected.transform,
								model.bounds,
								mouse_pos,
								viewport_size,
							)
						}
					}
					if axis != .None {
						active_gizmo_axis = axis
						selected := gfx.instance_get(&app.engine, app.engine.scene.selected_instance)
						drag_origin = selected.transform.translation
						drag_direction =
							gfx.gizmo_translation_axis_direction(selected.transform, axis, translation_space) if gizmo_mode == .Translate else gfx.gizmo_axis_direction(selected.transform, axis)
						if gizmo_mode == .Translate {
							drag_start_parameter, gizmo_dragging = gfx.gizmo_drag_parameter(
								active_cam^,
								drag_origin,
								drag_direction,
								mouse_pos,
								viewport_size,
							)
						} else {
							drag_previous_radial, gizmo_dragging = gfx.gizmo_rotation_radial(
								active_cam^,
								drag_origin,
								drag_direction,
								mouse_pos,
								viewport_size,
							)
							if gizmo_dragging {
								drag_start_radial = drag_previous_radial
								drag_sweep_angle = 0
							}
						}
					} else {
						gizmo_dragging = false
						active_gizmo_axis = .None
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
				if ev.button.button == sdl.BUTTON_LEFT do gizmo_dragging = false
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
		app.engine.scene.point_lights[point_light_index].pos =
			gfx.instance_get(&app.engine, light_sphere).transform.translation
		if app.fps_timer >= 1.0 {
			app.avg_fps = app.fps_frame_count
			log.infof("FPS: %d, models drawn: %d", app.fps_frame_count, app.engine.drawn_instance_count)
			log.infof("(%v) Camera position: %v", app.engine.scene.active_camera_name, active_cam.position)
			log.infof("Point light position: %v", app.engine.scene.point_lights[point_light_index].pos)
			log.infof(
				"Shiny cube position: %v",
				gfx.instance_get(&app.engine, shiny_cube_instance).transform.translation,
			)
			log.infof(
				"Rough cube position: %v",
				gfx.instance_get(&app.engine, rough_cube_instance).transform.translation,
			)
			app.fps_frame_count = 0
			app.fps_timer = 0
		}

		if app.engine.scene.selected_instance != gfx.INVALID_INSTANCE {
			selected := gfx.instance_get(&app.engine, app.engine.scene.selected_instance)
			if gizmo_mode == .Translate {
				gfx.gizmo_draw_translation(
					&app.engine,
					selected.transform,
					active_gizmo_axis,
					gizmo_dragging,
					translation_space,
				)
			} else {
				model := gfx.pool_get(&app.engine.model_system.models, selected.model)
				gfx.gizmo_draw_rotation(
					&app.engine,
					selected.transform,
					model.bounds,
					active_gizmo_axis,
					gizmo_dragging,
					drag_start_radial,
					drag_sweep_angle,
				)
			}
		}

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

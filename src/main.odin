package main

import "core:log"
import "core:math"
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

	mouse_captured := true
	_ = sdl.SetWindowRelativeMouseMode(app.window, true)


	init_ok := gfx.initialize_vulkan(&app)
	if !init_ok {
		log.errorf("Failed to initialize Vulkan")
		return
	}
	defer gfx.engine_shutdown(&app.engine)

	wood_gate_mat := gfx.create_material(
		&app.engine,
		"wood_gate",
		base_color_texture = gfx.texture_load(&app.engine, "assets/textures/wooden_gate_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(&app.engine, "assets/textures/wooden_gate_nor_gl_4k.jpg", false),
		metallic_roughness_texture = gfx.texture_load(&app.engine, "assets/textures/wooden_gate_arm_4k.jpg", false),
		occlusion_texture = gfx.texture_load(&app.engine, "assets/textures/wooden_gate_ao_4k.png", false),
	)
	wood_gate := gfx.load_model(&app.engine, "assets/models/wooden_gate_4k.gltf", wood_gate_mat)
	gfx.spawn(&app.engine, wood_gate, gfx.transform_create(translation = {0, 1, -2}))

	lion_head_mat := gfx.create_material(
		&app.engine,
		"lion_head",
		base_color_texture = gfx.texture_load(&app.engine, "assets/models/textures/lion_head_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(&app.engine, "assets/models/textures/lion_head_nor_gl_4k.jpg", false),
		metallic_roughness_texture = gfx.texture_load(
			&app.engine,
			"assets/models/textures/lion_head_arm_4k.jpg",
			false,
		),
		occlusion_texture = gfx.texture_load(&app.engine, "assets/models/textures/lion_head_arm_4k.jpg", false),
	)
	lion_head := gfx.load_model(&app.engine, "assets/models/lion_head_4k.gltf", lion_head_mat)
	gfx.spawn(&app.engine, lion_head, gfx.transform_create(translation = {0, 1.5, 0}))

	boulder_mat := gfx.create_material(
		&app.engine,
		"boulder",
		base_color_texture = gfx.texture_load(
			&app.engine,
			"assets/models/textures/namaqualand_boulder_02_diff_4k.jpg",
		),
		normal_map_texture = gfx.texture_load(
			&app.engine,
			"assets/models/textures/namaqualand_boulder_02_nor_gl_4k.jpg",
			false,
		),
		metallic_roughness_texture = gfx.texture_load(
			&app.engine,
			"assets/models/textures/namaqualand_boulder_02_arm_4k.jpg",
			false,
		),
		occlusion_texture = gfx.texture_load(
			&app.engine,
			"assets/models/textures/namaqualand_boulder_02_arm_4k.jpg",
			false,
		),
	)
	boulder := gfx.load_model(&app.engine, "assets/models/namaqualand_boulder_02_4k.gltf", boulder_mat)
	gfx.spawn(&app.engine, boulder, gfx.transform_create(translation = {3, 0.06, 2}))

	duck_mat := gfx.create_material(
		&app.engine,
		"duck",
		base_color_texture = gfx.texture_load(&app.engine, "assets/models/textures/rubber_duck_toy_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(
			&app.engine,
			"assets/models/textures/rubber_duck_toy_nor_gl_4k.jpg",
			false,
		),
		metallic_roughness_texture = gfx.texture_load(
			&app.engine,
			"assets/models/textures/rubber_duck_toy_arm_4k.jpg",
			false,
		),
		occlusion_texture = gfx.texture_load(&app.engine, "assets/models/textures/rubber_duck_toy_arm_4k.jpg", false),
	)
	duck := gfx.load_model(&app.engine, "assets/models/rubber_duck_toy_4k.gltf", duck_mat)
	gfx.spawn(&app.engine, duck, gfx.transform_create(translation = {-3, 0, 2}))


	shiny_mat := gfx.create_material(&app.engine, "shiny_mat", perceptual_roughness = 0.0)
	rough_mat := gfx.create_material(&app.engine, "rough_mat", perceptual_roughness = 1.0)
	shiny_cube := gfx.create_cube(&app.engine, "shiny_cube", shiny_mat)
	rough_cube := gfx.create_cube(&app.engine, "rough_cube", rough_mat)
	gfx.spawn(&app.engine, shiny_cube, gfx.transform_create(translation = {-2, 1, 0}))
	gfx.spawn(&app.engine, rough_cube, gfx.transform_create(translation = {2, 1, 0}))

	sponza := gfx.load_model(&app.engine, "assets/models/sponza-gltf-pbr/sponza.glb")
	gfx.spawn(&app.engine, sponza, gfx.transform_create(translation = {0, 0, 0}, scale = {0.01, 0.01, 0.01}))

	space_skybox_tex := gfx.texture_load_cubemap(&app.engine, "assets/textures/StandardCubeMap.png")
	gfx.set_skybox_texture(&app.engine, space_skybox_tex)

	gfx.spawn_point_light(
		&app.engine,
		gfx.PointLight {
			pos = {0, 10, 0},
			color = {1, 1, 0},
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
			pos = {2, 2, 4},
			direction = {0, -0.26, -1},
			color = {0.4, 0.5, 0.7},
			inner_cutoff = math.cos(math.to_radians(f32(12.5))),
			outer_cutoff = math.cos(math.to_radians(f32(22.5))),
			constant = 1,
			linear = 0.09,
			quadratic = 0.032,
			diffuse_intensity = 1.0,
			specular_intensity = 1.0,
		},
	)
	gfx.spawn_directional_light(
		&app.engine,
		gfx.DirectionalLight {
			direction = linalg.normalize(gfx.Vec3{-1.0, -1.0, 0.5}),
			color = {1.0, 0.9, 0.8},
			diffuse_intensity = 1.0,
			specular_intensity = 1.0,
		},
	)

	// sphere_model := gfx.create_sphere(&app.engine, "sphere")
	// sphere := gfx.spawn(&app.engine, sphere_model, gfx.transform_create(translation = {0, 2.5, 0}))

	yellow_mat := gfx.create_material(&app.engine, "yellow_mat", base_color = {1, 1, 0, 1})
	light_sphere_model := gfx.create_sphere(&app.engine, "light_sphere", material = yellow_mat)
	light_sphere := gfx.spawn(&app.engine, light_sphere_model, gfx.transform_create(scale = {0.2, 0.2, 0.2}))

	gfx.spawn_point_light(
		&app.engine,
		gfx.PointLight {
			pos = {0, 10, 0},
			color = {0.2, 0.5, 1},
			constant = 1,
			linear = 0.09,
			quadratic = 0.032,
			diffuse_intensity = 1.0,
			specular_intensity = 0.5,
		},
	)
	light_sphere2 := gfx.spawn(&app.engine, light_sphere_model, gfx.transform_create(scale = {0.2, 0.2, 0.2}))

	light_elapsed: f32
	main_loop: for {
		ev: sdl.Event

		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				#partial switch ev.key.scancode {
				case .ESCAPE:
					mouse_captured = !mouse_captured
					_ = sdl.SetWindowRelativeMouseMode(app.window, mouse_captured)
				case ._1:
					app.engine.scene.camera.near = 0.1
					app.engine.scene.camera.far = 5000.0
				case ._2:
					app.engine.scene.camera.near = 0.1
					app.engine.scene.camera.far = 20.0
				case ._3:
					app.engine.scene.camera.near = 20.0
					app.engine.scene.camera.far = 80.0
				case ._4:
					app.engine.scene.camera.near = 80.0
					app.engine.scene.camera.far = 400.0
				}
			case .MOUSE_MOTION:
				if mouse_captured do gfx.camera_process_mouse_movement(&app.engine.scene.camera, ev.motion.xrel, -ev.motion.yrel)
			case .MOUSE_WHEEL:
				gfx.camera_process_mouse_scroll(&app.engine.scene.camera, ev.wheel.y)
			case .WINDOW_PIXEL_SIZE_CHANGED:
				app.width = u32(ev.window.data1)
				app.height = u32(ev.window.data2)
				app.engine.swapchain.require_recreate = true
			}
		}

		now := time.now()
		app.engine.clock.delta_time = f32(time.duration_seconds(time.diff(app.engine.clock.last_frame_time, now)))
		app.engine.clock.last_frame_time = now

		app.engine.clock.fps_frame_count += 1
		app.engine.clock.fps_timer += app.engine.clock.delta_time
		if app.engine.clock.fps_timer >= 1.0 {
			log.infof("FPS: %d, models drawn: %d", app.engine.clock.fps_frame_count, app.engine.drawn_instance_count)
			log.infof("Camera position: %v", app.engine.scene.camera.position)
			app.engine.clock.fps_frame_count = 0
			app.engine.clock.fps_timer = 0
		}

		light_pos := gfx.Vec3{-2, 4, 0}
		light_pos2 := gfx.Vec3{2, 4, 0}
		app.engine.scene.point_lights[0].pos = light_pos
		app.engine.scene.point_lights[1].pos = light_pos2
		gfx.get_instance(&app.engine, light_sphere).transform.translation = light_pos
		gfx.get_instance(&app.engine, light_sphere2).transform.translation = light_pos2

		process_input(&app.engine, app.engine.clock.delta_time)
		gfx.engine_render(&app)
	}
}

process_input :: proc(engine: ^gfx.Engine, dt: f32) {
	keys := sdl.GetKeyboardState(nil)

	if keys[sdl.Scancode.W] do gfx.camera_process_keyboard(&engine.scene.camera, .Forward, dt)
	if keys[sdl.Scancode.S] do gfx.camera_process_keyboard(&engine.scene.camera, .Backward, dt)
	if keys[sdl.Scancode.A] do gfx.camera_process_keyboard(&engine.scene.camera, .Left, dt)
	if keys[sdl.Scancode.D] do gfx.camera_process_keyboard(&engine.scene.camera, .Right, dt)
	if keys[sdl.Scancode.SPACE] do gfx.camera_process_keyboard(&engine.scene.camera, .Up, dt)
	if keys[sdl.Scancode.LCTRL] do gfx.camera_process_keyboard(&engine.scene.camera, .Down, dt)
}


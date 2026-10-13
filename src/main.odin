package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:time"

import sdl "vendor:sdl3"

import gfx "veil:graphics"
import "veil:handles"

main :: proc() {
	// Tracks every heap allocation for the stats overlay and reports leaks at exit. Set up
	// before anything allocates, so every free goes back through it.
	// Debug builds only (`just debug`): every allocation pays for a map insert.
	when ODIN_DEBUG {
		heap_tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&heap_tracker, context.allocator)
		context.allocator = mem.tracking_allocator(&heap_tracker)
		defer {
			for _, leak in heap_tracker.allocation_map {
				fmt.eprintfln("leak: %d bytes at %v", leak.size, leak.location)
			}
			mem.tracking_allocator_destroy(&heap_tracker)
		}
	}

	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)

	ok := sdl.InitSubSystem({.VIDEO})
	if !ok {
		log.errorf("Failed to init")
		return
	}
	defer sdl.Quit()

	engine: gfx.Engine
	world: World
	width, height := u32(1280), u32(720)
	window: ^sdl.Window

	window = sdl.CreateWindow("veil", i32(width), i32(height), {.VULKAN, .RESIZABLE})
	if window == nil {
		log.errorf("Failed to create window: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	// Starts free so the window doesn't grab the cursor on launch; Esc toggles mouse look.
	mouse_captured := false

	init_ok := gfx.engine_create(&engine, window, width, height)
	if !init_ok {
		// Fatal by design: no engine_destroy, the process exit reclaims everything.
		log.errorf("Failed to initialize the engine")
		return
	}
	when ODIN_DEBUG do gfx.stats_track_heap(&engine, &heap_tracker)
	defer gfx.engine_destroy(&engine)

	ui_font, font_ok := gfx.font_load_default_system(&engine, 20)
	assert(font_ok, "no default system font found")
	// Declared after engine_destroy's defer, so it runs first.
	defer gfx.font_destroy(&engine, &ui_font)

	// Entities hold engine model handles: created after the engine, so destroyed before it.
	world_create(&world)
	defer world_destroy(&world)

	last_frame_time := time.now()

	load_max_instances(&engine, &world)
	if !entity_alive(&world, world.active_camera) {
		world.active_camera = entity_spawn_camera(&world, gfx.camera_create())
	}

	// The game owns the render settings and hands a copy to the renderer in each packet.
	settings := gfx.RENDER_SETTINGS_DEFAULT
	gfx.render_settings_from_env(&settings)

	gizmo: GizmoController
	show_stats := true
	post_control: PostControl
	main_loop: for {
		// Game-side temp allocations live for one loop iteration; the engine resets its own
		// frame arena inside engine_render.
		defer free_all(context.temp_allocator)

		ev: sdl.Event
		// The active camera's rig: controls edit it, and it drives the entity's transform below.
		active_cam := &entity_get(&world, world.active_camera).camera

		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				#partial switch ev.key.scancode {
				case .ESCAPE:
					gizmo_cancel(&gizmo)
					mouse_captured = !mouse_captured
					_ = sdl.SetWindowRelativeMouseMode(window, mouse_captured)
				case .G:
					gizmo_set_mode(&gizmo, .Translate)
				case .R:
					gizmo_set_mode(&gizmo, .Rotate)
				case .L:
					gizmo_toggle_space(&gizmo)
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
					settings.cascade_colors = !settings.cascade_colors
				case .V:
					settings.shadows = !settings.shadows
					log.infof("shadows: %v", settings.shadows)
				case .P:
					settings.lights ~= {.Point}
					log.infof("lights: %v", settings.lights)
				case .K:
					settings.lights ~= {.Spot}
					log.infof("lights: %v", settings.lights)
				case .J:
					settings.lights ~= {.Directional}
					log.infof("lights: %v", settings.lights)
				case .LEFT:
					post_control_cycle(&post_control, -1)
				case .RIGHT:
					post_control_cycle(&post_control, 1)
				case .UP:
					post_control_step(&active_cam.post, post_control, 1)
				case .DOWN:
					post_control_step(&active_cam.post, post_control, -1)
				case .X:
					settings.particles = !settings.particles
					log.infof("particles: %v", settings.particles)
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
						if entity_alive(&world, world.selected) {
							target = gfx.matrix_translation(entity_get(&world, world.selected).global_transform)
						}
						gfx.camera_orbit_begin(active_cam, target)
					}
				}
			case .MOUSE_MOTION:
				if mouse_captured {
					camera_process_mouse_movement(active_cam, ev.motion.xrel, -ev.motion.yrel)
				} else if gizmo.dragging {
					mouse_pos, ok := mouse_to_pixels(window, &engine, ev.motion.x, ev.motion.y)
					if ok do gizmo_mouse_move(&gizmo, &engine, &world, world_camera(&world), mouse_pos)
				}
			case .MOUSE_BUTTON_DOWN:
				if !mouse_captured && ev.button.button == sdl.BUTTON_LEFT {
					mouse_pos, ok := mouse_to_pixels(window, &engine, ev.button.x, ev.button.y)
					if !ok do continue
					if !gizmo_mouse_down(&gizmo, &engine, &world, world_camera(&world), mouse_pos) {
						world.selected = world_pick(&engine, &world, mouse_pos)
						if world.selected != INVALID_ENTITY {
							log.infof(
								"selected: %v",
								gfx.model_name(&engine, entity_get(&world, world.selected).model),
							)
						}
					}
				}
			case .MOUSE_BUTTON_UP:
				if ev.button.button == sdl.BUTTON_LEFT do gizmo_mouse_up(&gizmo)
			case .MOUSE_WHEEL:
				camera_process_mouse_scroll(active_cam, ev.wheel.y)
			case .WINDOW_PIXEL_SIZE_CHANGED:
				width = u32(ev.window.data1)
				height = u32(ev.window.data2)
			}
		}

		now := time.now()
		delta_time := f32(time.duration_seconds(time.diff(last_frame_time, now)))
		last_frame_time = now

		process_input(active_cam, delta_time)
		entity_get(&world, world.active_camera).transform = camera_rig_transform(active_cam^)

		world_flush(&world)
		world_update(&world, delta_time)
		packet := world_extract(&world)

		// Debug lines, text and views for this frame; game temp memory, so a skipped frame drops nothing it has to drain.
		overlay := gfx.overlay_make()
		packet.settings = settings
		packet.overlay = &overlay
		gizmo_draw(&gizmo, &engine, &overlay, &world, packet.camera)
		if show_stats {
			post_line := post_control_line(&engine, packet.camera.post, post_control)
			gfx.stats_draw(&engine, &overlay, &ui_font, 10, 24, 24, {post_line})
		}

		gfx.engine_render(&engine, &packet, width, height)
	}
}

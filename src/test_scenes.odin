package main

import "core:math/linalg"

import gfx "graphics"

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
	// The file is one mesh with a primitive per material, so splitting primitives is the only way to
	// get separately pickable pieces. The root node's 0.008 scale brings it to meters.
	sponza := gfx.model_load_parts(engine, "assets/models/sponza-gltf-pbr/sponza.glb", split_primitives = true)
	gfx.instance_spawn_parts(engine, sponza, gfx.transform_create())

	// West end of the atrium, looking down its long (+x) axis.
	engine.camera_system.default_camera = gfx.camera_create({-9.6, 1.44, 0}, yaw = 0, pitch = 5)

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
			// atrium is ~24 m long
			shadow_maximum_distance = 32.0,
		},
	)

	// Fire light above the four wall-mounted torch bowls on the inner columns.
	torches := [?]gfx.Vec3{{3.9, 1.92, -1.6}, {-4.95, 1.92, -1.6}, {3.9, 1.92, 1.0}, {-4.95, 1.92, 1.0}}
	for pos in torches {
		gfx.light_spawn_point(
			engine,
			gfx.PointLight {
				pos = pos,
				range = 8.0,
				shadow_near = 0.1,
				color = {1.0, 0.6, 0.3},
				constant = 1,
				linear = 0.275,
				quadratic = 0.31,
				diffuse_intensity = 1.5,
				specular_intensity = 0.5,
			},
		)
	}
}

// Neon spheres and cubes over a plain floor, dim ambient. The left three carry a matching point light
// so they light the floor; the right three only emit, so they glow (bloom) without lighting anything.
load_bloom_test :: proc(engine: ^gfx.Engine) {
	NeonShape :: enum {
		Sphere,
		Cube,
	}
	Neon :: struct {
		name:  string,
		shape: NeonShape,
		color: gfx.Vec3, // display color, scaled by NEON_STRENGTH for the HDR emission
		lit:   bool,
	}
	NEON_STRENGTH :: 15.0
	neons := [?]Neon {
		{"neon_cyan", .Sphere, {0.0, 1.0, 1.0}, true},
		{"neon_magenta", .Cube, {1.0, 0.0, 0.8}, true},
		{"neon_green", .Sphere, {0.2, 1.0, 0.1}, true},
		{"neon_orange", .Cube, {1.0, 0.4, 0.05}, false},
		{"neon_purple", .Sphere, {0.5, 0.1, 1.0}, false},
		{"neon_yellow", .Cube, {1.0, 0.9, 0.1}, false},
	}
	xs := [len(neons)]f32{-6, -4, -2, 2, 4, 6}

	// Primitives are cached by name, so each shape is built once and shared by every material.
	for neon, i in neons {
		mat := gfx.material_create(engine, neon.name, base_color = {0, 0, 0, 1}, emissive = neon.color * NEON_STRENGTH)
		model: gfx.ModelHandle
		switch neon.shape {
		case .Sphere:
			model = gfx.primitive_sphere(engine, neon.name, mat, radius = 0.4)
		case .Cube:
			model = gfx.primitive_cube(engine, neon.name, mat, half_size = {0.35, 0.35, 0.35})
		}
		pos := gfx.Vec3{xs[i], 0.8, -2}
		gfx.instance_spawn(engine, model, gfx.transform_create(translation = pos))

		if !neon.lit do continue
		// shadow_near is past the shape's extent (cube corner ~0.61) so it clips out of its own
		// shadow map instead of blocking its light.
		gfx.light_spawn_point(
			engine,
			gfx.PointLight {
				pos = pos,
				range = 6.0,
				shadow_near = 0.7,
				color = neon.color,
				constant = 1,
				linear = 0.22,
				quadratic = 0.2,
				diffuse_intensity = 4.0,
				specular_intensity = 1.0,
			},
		)
	}

	floor_mat := gfx.material_create(
		engine,
		"bloom_floor",
		base_color = {0.5, 0.5, 0.5, 1},
		perceptual_roughness = 0.8,
	)
	floor := gfx.primitive_plane(engine, "bloom_floor", floor_mat, half_size = {12, 12})
	gfx.instance_spawn(engine, floor, gfx.transform_create())

	engine.camera_system.default_camera = gfx.camera_create({0, 2.5, 6}, yaw = -90, pitch = -15)
	engine.scene.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.05,
	}
}

// Transparent meshes in front of opaque ones, overlapping each other at different depths, so the
// back-to-front order and the depth test against opaque geometry are both visible.
load_transparency_test :: proc(engine: ^gfx.Engine) {
	floor_mat := gfx.material_create(
		engine,
		"transparency_floor",
		base_color = {0.5, 0.5, 0.5, 1},
		perceptual_roughness = 0.8,
	)
	floor := gfx.primitive_plane(engine, "transparency_floor", floor_mat, half_size = {12, 12})
	gfx.instance_spawn(engine, floor, gfx.transform_create())

	// Opaque shapes behind the glass.
	solid_mat := gfx.material_create(
		engine,
		"transparency_solid",
		base_color = {0.8, 0.8, 0.8, 1},
		perceptual_roughness = 0.5,
	)
	solid := gfx.primitive_cube(engine, "transparency_solid", solid_mat, half_size = {0.5, 0.5, 0.5})
	for x in ([?]f32{-3, 0, 3}) {
		gfx.instance_spawn(engine, solid, gfx.transform_create(translation = {x, 0.5, -4}))
	}

	Glass :: struct {
		name:  string,
		color: gfx.Vec4,
		pos:   gfx.Vec3,
		cube:  bool,
	}
	glasses := [?]Glass {
		{"glass_red", {1.0, 0.1, 0.1, 0.4}, {-1.5, 0.8, -2.5}, true},
		{"glass_green", {0.1, 1.0, 0.2, 0.5}, {-0.8, 0.9, -1.5}, false},
		{"glass_blue", {0.1, 0.3, 1.0, 0.3}, {0.0, 0.8, -0.5}, true},
		{"glass_yellow", {1.0, 0.9, 0.1, 0.6}, {0.8, 0.9, -2.0}, false},
		{"glass_cyan", {0.1, 1.0, 1.0, 0.4}, {1.6, 0.8, -1.0}, true},
	}
	for glass in glasses {
		mat := gfx.material_create(
			engine,
			glass.name,
			base_color = glass.color,
			perceptual_roughness = 0.1,
			alpha_mode = .Blend,
		)
		model :=
			gfx.primitive_cube(engine, glass.name, mat, half_size = {0.6, 0.6, 0.6}) if glass.cube else gfx.primitive_sphere(engine, glass.name, mat, radius = 0.7)
		gfx.instance_spawn(engine, model, gfx.transform_create(translation = glass.pos))
	}

	gfx.spawn_directional_light(
		engine,
		gfx.DirectionalLight {
			direction = linalg.normalize(gfx.Vec3{-0.4, -1, -0.3}),
			color = {1, 1, 1},
			diffuse_intensity = 1.5,
			specular_intensity = 1,
			shadow_maximum_distance = 15,
		},
	)
	engine.camera_system.default_camera = gfx.camera_create({0, 2.0, 4}, yaw = -90, pitch = -12)
	engine.scene.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.15,
	}
}

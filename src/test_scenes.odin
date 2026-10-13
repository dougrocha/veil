package main

import "core:fmt"
import "core:math/linalg"

import gfx "veil:graphics"

// 4K scanned PBR models with their texture sets.
load_pbr_showcase :: proc(engine: ^gfx.Engine, world: ^World) {
	wood_gate_mat := gfx.material_create(
		engine,
		"wood_gate",
		base_color_texture = gfx.texture_load(engine, "assets/textures/wooden_gate_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(engine, "assets/textures/wooden_gate_nor_gl_4k.jpg", false),
		metallic_roughness_texture = gfx.texture_load(engine, "assets/textures/wooden_gate_arm_4k.jpg", false),
		occlusion_texture = gfx.texture_load(engine, "assets/textures/wooden_gate_ao_4k.png", false),
	)
	wood_gate := gfx.model_with_material(
		engine,
		gfx.model_load(engine, "assets/models/wooden_gate_4k.gltf"),
		wood_gate_mat,
	)
	entity_spawn_model(world, wood_gate, gfx.transform_create(translation = {0, 1, -2}))

	lion_head_mat := gfx.material_create(
		engine,
		"lion_head",
		base_color_texture = gfx.texture_load(engine, "assets/models/textures/lion_head_diff_4k.jpg"),
		normal_map_texture = gfx.texture_load(engine, "assets/models/textures/lion_head_nor_gl_4k.jpg", false),
		metallic_roughness_texture = gfx.texture_load(engine, "assets/models/textures/lion_head_arm_4k.jpg", false),
		occlusion_texture = gfx.texture_load(engine, "assets/models/textures/lion_head_arm_4k.jpg", false),
	)
	lion_head := gfx.model_with_material(
		engine,
		gfx.model_load(engine, "assets/models/lion_head_4k.gltf"),
		lion_head_mat,
	)
	entity_spawn_model(world, lion_head, gfx.transform_create(translation = {0, 1.5, 0}))

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
	boulder := gfx.model_with_material(
		engine,
		gfx.model_load(engine, "assets/models/namaqualand_boulder_02_4k.gltf"),
		boulder_mat,
	)
	entity_spawn_model(world, boulder, gfx.transform_create(translation = {3, 0.06, 2}))

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
	duck := gfx.model_with_material(engine, gfx.model_load(engine, "assets/models/rubber_duck_toy_4k.gltf"), duck_mat)
	entity_spawn_model(world, duck, gfx.transform_create(translation = {-3, 0, 2}))
}

load_sponza :: proc(engine: ^gfx.Engine, world: ^World) {
	world.background = gfx.texture_load_cubemap(engine, "assets/textures/StandardCubeMap.png")

	// The file is one mesh with a primitive per material, so splitting primitives is the only way to
	// get separately pickable pieces. The root node's 0.008 scale brings it to meters.
	sponza := gfx.model_load_parts(engine, "assets/models/sponza-gltf-pbr/sponza.glb", split_primitives = true)
	entity_spawn_parts(world, sponza, gfx.transform_create())

	// West end of the atrium, looking down its long (+x) axis.
	world.active_camera = entity_spawn_camera(world, gfx.camera_create({-9.6, 1.44, 0}, yaw = 0, pitch = 5))

	// No GI, so the arcades rely on ambient to stay readable.
	world.lights.ambient_light = gfx.AmbientLight {
		color      = {0.6, 0.7, 1.0, 1},
		brightness = 0.3,
	}
	// Steep sun through the open roof, tilted across the short (z) axis so one arcade is lit
	// and the gallery columns cast long shadows on the floor.
	light_spawn_directional(
		&world.lights,
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
		light_spawn_point(
			&world.lights,
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
load_bloom_test :: proc(engine: ^gfx.Engine, world: ^World) {
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

	// Primitive shapes are cached by size, so each shape is built once and bound to each material.
	for neon, i in neons {
		mat := gfx.material_create(engine, neon.name, base_color = {0, 0, 0, 1}, emissive = neon.color * NEON_STRENGTH)
		model: gfx.ModelHandle
		switch neon.shape {
		case .Sphere:
			model = gfx.model_with_material(engine, gfx.primitive_sphere(engine, radius = 0.4), mat)
		case .Cube:
			model = gfx.model_with_material(engine, gfx.primitive_cube(engine, half_size = {0.35, 0.35, 0.35}), mat)
		}
		pos := gfx.Vec3{xs[i], 0.8, -2}
		shape := entity_spawn_model(world, model, gfx.transform_create(translation = pos))

		if !neon.lit do continue
		// shadow_near is past the shape's extent (cube corner ~0.61) so it clips out of its own
		// shadow map instead of blocking its light.
		light := light_spawn_point(
			&world.lights,
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
		// The light moves with its shape.
		light_attach_point(world, light, shape)
	}

	floor_mat := gfx.material_create(
		engine,
		"bloom_floor",
		base_color = {0.5, 0.5, 0.5, 1},
		perceptual_roughness = 0.8,
	)
	floor := gfx.model_with_material(engine, gfx.primitive_plane(engine, half_size = {12, 12}), floor_mat)
	entity_spawn_model(world, floor, gfx.transform_create())

	world.active_camera = entity_spawn_camera(world, gfx.camera_create({0, 2.5, 6}, yaw = -90, pitch = -15))
	world.lights.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.05,
	}
}

// Transparent meshes in front of opaque ones, overlapping each other at different depths, so the
// back-to-front order and the depth test against opaque geometry are both visible.
load_transparency_test :: proc(engine: ^gfx.Engine, world: ^World) {
	floor_mat := gfx.material_create(
		engine,
		"transparency_floor",
		base_color = {0.5, 0.5, 0.5, 1},
		perceptual_roughness = 0.8,
		double_sided = true,
	)
	floor := gfx.model_with_material(engine, gfx.primitive_plane(engine, half_size = {12, 12}), floor_mat)
	entity_spawn_model(world, floor, gfx.transform_create())

	// Opaque shapes behind the glass.
	solid_mat := gfx.material_create(
		engine,
		"transparency_solid",
		base_color = {0.8, 0.8, 0.8, 1},
		perceptual_roughness = 0.5,
	)
	solid := gfx.model_with_material(engine, gfx.primitive_cube(engine, half_size = {0.5, 0.5, 0.5}), solid_mat)
	for x in ([?]f32{-3, 0, 3}) {
		entity_spawn_model(world, solid, gfx.transform_create(translation = {x, 0.501, -4}))
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
		model := gfx.model_with_material(
			engine,
			gfx.primitive_cube(engine, half_size = {0.6, 0.6, 0.6}) if glass.cube else gfx.primitive_sphere(engine, radius = 0.7),
			mat,
		)
		entity_spawn_model(world, model, gfx.transform_create(translation = glass.pos))
	}

	light_spawn_directional(
		&world.lights,
		gfx.DirectionalLight {
			direction = linalg.normalize(gfx.Vec3{-0.4, -1, -0.3}),
			color = {1, 1, 1},
			diffuse_intensity = 1.5,
			specular_intensity = 1,
			shadow_maximum_distance = 15,
		},
	)
	world.active_camera = entity_spawn_camera(world, gfx.camera_create({0, 2.0, 4}, yaw = -90, pitch = -12))
	world.lights.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.15,
	}
}

// A cube, a sphere and a tall box on a floor, lit by one point light inside the sphere,
// so each shadow's shape is easy to read. Drag objects with the gizmo to check the shadow cache.
load_shadow_test :: proc(engine: ^gfx.Engine, world: ^World) {
	floor_mat := gfx.material_create(
		engine,
		"shadow_floor",
		base_color = {0.6, 0.6, 0.6, 1},
		perceptual_roughness = 0.8,
	)
	floor := gfx.model_with_material(engine, gfx.primitive_plane(engine, half_size = {12, 12}), floor_mat)
	entity_spawn_model(world, floor, gfx.transform_create())

	solid_mat := gfx.material_create(
		engine,
		"shadow_solid",
		base_color = {0.8, 0.8, 0.8, 1},
		perceptual_roughness = 0.5,
	)
	cube := gfx.model_with_material(engine, gfx.primitive_cube(engine, half_size = {0.5, 0.5, 0.5}), solid_mat)
	sphere := gfx.model_with_material(engine, gfx.primitive_sphere(engine, radius = 0.5), solid_mat)
	pillar := gfx.model_with_material(engine, gfx.primitive_cube(engine, half_size = {0.25, 1, 0.25}), solid_mat)
	entity_spawn_model(world, cube, gfx.transform_create(translation = {-2, 0.5, 0}))
	entity_spawn_model(world, sphere, gfx.transform_create(translation = {0, 0.5, 0}))
	entity_spawn_model(world, pillar, gfx.transform_create(translation = {2, 1, 0}))

	light_spawn_point(
		&world.lights,
		gfx.PointLight {
			pos                = {0, 0.5, 0}, // sphere center
			range              = 12,
			shadow_near        = 0.6, // past the sphere radius (0.5), so the sphere clips out of its own map
			color              = {1, 1, 1},
			constant           = 1,
			linear             = 0.09,
			quadratic          = 0.032,
			diffuse_intensity  = 2,
			specular_intensity = 0.5,
		},
	)

	world.active_camera = entity_spawn_camera(world, gfx.camera_create({0, 4, 7}, yaw = -90, pitch = -30))
	world.lights.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.05,
	}
}

// Cornell box, ported from 3DWorld (cornell_box/coll_objs_box.txt). 3DWorld is Z-up; positions are
// converted as (x, y, z) -> (x, z + 0.9, -y), so the floor top is at y = 0. The front wall is left
// out so the camera can see in, and the glass sphere is opaque. One spot light under the ceiling
// points down.
load_cornell_box :: proc(engine: ^gfx.Engine, world: ^World) {
	Wall :: struct {
		name:         string,
		center, half: gfx.Vec3,
		color:        gfx.Vec3,
	}
	walls := [?]Wall {
		{"cornell_top", {0, 1.0, 0}, {1, 0.1, 1}, {1, 1, 1}},
		{"cornell_bottom", {0, -0.05, 0}, {1, 0.05, 1}, {1, 1, 1}},
		{"cornell_back", {0, 0.45, -0.95}, {1, 0.55, 0.05}, {1, 1, 1}},
		{"cornell_left", {-0.95, 0.45, 0}, {0.05, 0.45, 0.9}, {1, 0, 0}},
		{"cornell_right", {0.95, 0.45, 0}, {0.05, 0.45, 0.9}, {0, 1, 0}},
		{"cornell_box", {-0.25, 0.31, 0.25}, {0.15, 0.29, 0.15}, {1, 1, 1}},
	}
	for wall in walls {
		mat := gfx.material_create(
			engine,
			wall.name,
			base_color = {wall.color.r, wall.color.g, wall.color.b, 1} * 0.8,
			perceptual_roughness = 0.9,
		)
		cube := gfx.model_with_material(engine, gfx.primitive_cube(engine, wall.half), mat)
		entity_spawn_model(world, cube, gfx.transform_create(translation = wall.center))
	}

	sphere_mat := gfx.material_create(
		engine,
		"cornell_sphere",
		base_color = {0.8, 0.8, 0.8, 1},
		perceptual_roughness = 0.1,
	)
	sphere := gfx.model_with_material(engine, gfx.primitive_sphere(engine, radius = 0.25), sphere_mat)
	entity_spawn_model(world, sphere, gfx.transform_create(translation = {0.4, 0.3, -0.3}))

	light_spawn_spot(
		&world.lights,
		gfx.SpotLight {
			pos = {0, 0.8, 0},
			direction = {0, -1, 0},
			range = 3,
			shadow_near = 0.05,
			inner_cutoff = linalg.cos(linalg.to_radians(f32(60))),
			outer_cutoff = linalg.cos(linalg.to_radians(f32(75))),
			constant = 1,
			linear = 0.7,
			quadratic = 1.8,
			color = {1, 1, 1},
			diffuse_intensity = 3,
			specular_intensity = 0.5,
		},
	)

	world.active_camera = entity_spawn_camera(world, gfx.camera_create({0, 0.45, 2.4}, yaw = -90, pitch = 0))
	world.lights.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.03,
	}
}

// Capacity stress test: a floor plus cubes and spheres on a 64 x 64 grid, using 4096 entities, and 8 point lights, 4 spots, and 2 suns. Point lights are in a ring over the
// grid, spots at its corners pointing down, both directional lights cast cascades.
load_max_instances :: proc(engine: ^gfx.Engine, world: ^World) {
	GRID :: 64
	SPACING :: f32(1.25)
	#assert(GRID * GRID < MAX_ENTITIES) // plus the camera
	half_extent := f32(GRID - 1) * SPACING / 2

	floor_mat := gfx.material_create(engine, "max_floor", base_color = {0.5, 0.5, 0.5, 1}, perceptual_roughness = 0.8)
	floor := gfx.model_with_material(
		engine,
		gfx.primitive_plane(engine, half_size = {half_extent + 2, half_extent + 2}),
		floor_mat,
	)
	entity_spawn_model(world, floor, gfx.transform_create())

	// One cube and one sphere model per color, bound to the shared base shapes.
	colors := [?]gfx.Vec3 {
		{0.9, 0.2, 0.2},
		{0.2, 0.8, 0.3},
		{0.2, 0.4, 0.9},
		{0.9, 0.8, 0.2},
		{0.8, 0.3, 0.8},
		{0.2, 0.8, 0.8},
		{0.9, 0.5, 0.1},
		{0.8, 0.8, 0.8},
	}
	cubes, spheres: [len(colors)]gfx.ModelHandle
	for color, i in colors {
		mat := gfx.material_create(
			engine,
			fmt.tprintf("max_shape_%d", i),
			base_color = {color.r, color.g, color.b, 1},
			perceptual_roughness = 0.5,
		)
		cubes[i] = gfx.model_with_material(engine, gfx.primitive_cube(engine, half_size = {0.3, 0.3, 0.3}), mat)
		spheres[i] = gfx.model_with_material(engine, gfx.primitive_sphere(engine, radius = 0.3), mat)
	}

	// The floor takes one slot, so the last grid cell stays empty.
	for cell in 0 ..< GRID * GRID - 1 {
		x, z := cell % GRID, cell / GRID
		color := (x / 4 + z / 4) % len(colors)
		model := cubes[color] if (x + z) % 2 == 0 else spheres[color]
		pos := gfx.Vec3{f32(x) * SPACING - half_extent, 0.3, f32(z) * SPACING - half_extent}
		entity_spawn_model(world, model, gfx.transform_create(translation = pos))
	}

	for i in 0 ..< 8 {
		angle := f32(i) / 8 * linalg.TAU
		light_spawn_point(
			&world.lights,
			gfx.PointLight {
				pos = {linalg.cos(angle) * 16, 2.5, linalg.sin(angle) * 16},
				range = 10,
				shadow_near = 0.1,
				color = colors[i],
				constant = 1,
				linear = 0.14,
				quadratic = 0.07,
				diffuse_intensity = 3,
				specular_intensity = 0.5,
			},
		)
	}
	for i in 0 ..< 4 {
		corner := gfx.Vec2{-1 if i % 2 == 0 else 1, -1 if i / 2 == 0 else 1} * (half_extent - 8)
		light_spawn_spot(
			&world.lights,
			gfx.SpotLight {
				pos = {corner.x, 6, corner.y},
				direction = {0, -1, 0},
				range = 10,
				shadow_near = 0.1,
				inner_cutoff = linalg.cos(linalg.to_radians(f32(30))),
				outer_cutoff = linalg.cos(linalg.to_radians(f32(40))),
				constant = 1,
				linear = 0.09,
				quadratic = 0.032,
				color = {1, 1, 1},
				diffuse_intensity = 4,
				specular_intensity = 0.5,
			},
		)
	}
	sun_directions := [gfx.MAX_DIRECTIONAL_LIGHTS]gfx.Vec3{{0.3, -1, 0.4}, {-0.5, -1, -0.2}}
	for direction, i in sun_directions {
		light_spawn_directional(
			&world.lights,
			gfx.DirectionalLight {
				direction = linalg.normalize(direction),
				color = {1, 0.95, 0.85},
				diffuse_intensity = 0.8 if i == 0 else 0.3,
				specular_intensity = 0.3,
				shadow_maximum_distance = 60,
			},
		)
	}

	world.active_camera = entity_spawn_camera(
		world,
		gfx.camera_create({0, 30, half_extent + 20}, yaw = -90, pitch = -40),
	)
	world.lights.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.05,
	}
}

// Validation: one mesh fills the id budget, so a single GPU cull run spans 32 batches of 1024.
// The camera takes one entity slot, so the cubes fill the rest of MAX_ENTITIES.
load_cull_32k_single_run :: proc(engine: ^gfx.Engine, world: ^World) {
	COUNT :: MAX_ENTITIES - 1
	mat := gfx.material_create(engine, "cull_single_run", base_color = {0.8, 0.6, 0.3, 1}, perceptual_roughness = 0.5)
	cube := gfx.model_with_material(engine, gfx.primitive_cube(engine, half_size = {0.4, 0.4, 0.4}), mat)
	for i in 0 ..< COUNT {
		pos := gfx.Vec3{f32(i % 32) * 1.5 - 23.25, f32((i / 32) % 32) * 1.5 - 23.25, -f32(i / 1024) * 1.5}
		entity_spawn_model(world, cube, gfx.transform_create(translation = pos))
	}
	load_cull_validation_lighting(world)
	world.active_camera = entity_spawn_camera(world, gfx.camera_create({0, 0, 60}, yaw = -90, pitch = 0))
}

// Validation: 2048 red cubes in one run across two batches. Every third candidate is culled (x = 500), so
// each batch holds kept and culled ids, and batch 2 starts on a kept id (1024 % 3 == 1). Visible cubes sit
// on distinct cells, so a dropped or duplicated id shows as a hole or an extra cube in the image.
// The double-sided green run follows red, so its pipeline group starts after red's commands.
// Green and blue share one spot in front of the grid. Each is its own run, so their coplanar winner comes
// from run order. This image does not observe order within a run. Same-run coplanar pairs can differ in
// transform or texture, and the ordered match in gpu_cull_validate_frame covers that order.
load_cull_batch_boundary :: proc(engine: ^gfx.Engine, world: ^World) {
	red := gfx.model_with_material(
		engine,
		gfx.primitive_cube(engine, half_size = {0.2, 0.2, 0.2}),
		gfx.material_create(engine, "cull_boundary_red", base_color = {0.9, 0.1, 0.1, 1}, perceptual_roughness = 0.5),
	)
	for i in 0 ..< 2048 {
		pos := gfx.Vec3{f32(i % 64) * 0.5 - 15.75, f32(i / 64) * 0.5 - 7.75, 0}
		if i % 3 == 0 do pos = {500, 0, 0}
		entity_spawn_model(world, red, gfx.transform_create(translation = pos))
	}
	green := gfx.model_with_material(
		engine,
		gfx.primitive_cube(engine, half_size = {0.6, 0.6, 0.6}),
		gfx.material_create(
			engine,
			"cull_boundary_green",
			base_color = {0.1, 0.9, 0.1, 1},
			perceptual_roughness = 0.5,
			double_sided = true,
		),
	)
	blue := gfx.model_with_material(
		engine,
		gfx.primitive_cube(engine, half_size = {0.6, 0.6, 0.6}),
		gfx.material_create(engine, "cull_boundary_blue", base_color = {0.1, 0.1, 0.9, 1}, perceptual_roughness = 0.5),
	)
	entity_spawn_model(world, green, gfx.transform_create(translation = {0, 0, 1}))
	entity_spawn_model(world, blue, gfx.transform_create(translation = {0, 0, 1}))
	load_cull_validation_lighting(world)
	world.active_camera = entity_spawn_camera(world, gfx.camera_create({0, 0, 25}, yaw = -90, pitch = 0))
}

@(private = "file")
load_cull_validation_lighting :: proc(world: ^World) {
	light_spawn_directional(
		&world.lights,
		gfx.DirectionalLight {
			direction = linalg.normalize(gfx.Vec3{0.3, -1, 0.4}),
			color = {1, 0.95, 0.85},
			diffuse_intensity = 0.8,
			specular_intensity = 0.3,
			shadow_maximum_distance = 60,
		},
	)
	world.lights.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.05,
	}
}

// Hundreds of deterministic, short-range lights over simple geometry for clustered-culling work.
load_many_lights :: proc(engine: ^gfx.Engine, world: ^World) {
	floor_mat := gfx.material_create(engine, "many_lights_floor", base_color = {0.55, 0.55, 0.55, 1})
	floor := gfx.model_with_material(engine, gfx.primitive_plane(engine, half_size = {12, 12}), floor_mat)
	entity_spawn_model(world, floor, gfx.transform_create())

	shape_mat := gfx.material_create(engine, "many_lights_shapes", base_color = {0.65, 0.65, 0.65, 1})
	shape := gfx.model_with_material(engine, gfx.primitive_cube(engine, half_size = {0.35, 0.5, 0.35}), shape_mat)
	for x in 0 ..< 8 {
		for z in 0 ..< 8 {
			entity_spawn_model(
				world,
				shape,
				gfx.transform_create(translation = {f32(x) * 2.8 - 9.8, 0.5, f32(z) * 2.8 - 9.8}),
			)
		}
	}

	colors := [?]gfx.Vec3{{1, 0.24, 0.12}, {0.16, 0.42, 1}, {0.2, 1, 0.32}, {1, 0.72, 0.12}}
	for i in 0 ..< 256 {
		x, z := i % 16, i / 16
		light_spawn_point(
			&world.lights,
			gfx.PointLight {
				pos = {f32(x) * 1.4 - 10.5, 1.5, f32(z) * 1.4 - 10.5},
				range = 2.4,
				shadow_near = 0.1,
				color = colors[(x + z) % len(colors)],
				constant = 1,
				linear = 0.25,
				quadratic = 0.15,
				diffuse_intensity = 2,
				specular_intensity = 0.2,
			},
		)
	}
	for i in 0 ..< 3 {
		light_spawn_spot(
			&world.lights,
			gfx.SpotLight {
				pos = {f32(i - 1) * 7, 5, 0},
				direction = {0, -1, 0},
				range = 9,
				shadow_near = 0.1,
				inner_cutoff = linalg.cos(linalg.to_radians(f32(25))),
				outer_cutoff = linalg.cos(linalg.to_radians(f32(38))),
				constant = 1,
				linear = 0.12,
				quadratic = 0.04,
				color = colors[i],
				diffuse_intensity = 2,
				specular_intensity = 0.25,
			},
		)
	}

	world.active_camera = entity_spawn_camera(world, gfx.camera_create({0, 13, 23}, yaw = -90, pitch = -25))
	world.lights.ambient_light = gfx.AmbientLight {
		color      = {1, 1, 1, 1},
		brightness = 0.08,
	}
}

package graphics

import "core:log"
import "core:math/linalg"

AmbientLight :: struct {
	color:      Vec4,
	brightness: f32,
}

PointLight :: struct {
	pos:                                   Vec3,
	range, shadow_near:                    f32,
	color:                                 Vec3,
	constant, linear, quadratic:           f32,
	diffuse_intensity, specular_intensity: f32,
	attached:                              Maybe(InstanceHandle), // pos follows this instance
	local_pos:                             Vec3, // relative to the attached instance
}

DirectionalLight :: struct {
	direction:                                                      Vec3,
	color:                                                          Vec3,
	diffuse_intensity, specular_intensity, shadow_maximum_distance: f32,
}

SpotLight :: struct {
	pos:                                       Vec3,
	range, shadow_near, inner_cutoff:          f32,
	direction:                                 Vec3,
	outer_cutoff, constant, linear, quadratic: f32,
	color:                                     Vec3,
	diffuse_intensity, specular_intensity:     f32,
	attached:                                  Maybe(InstanceHandle), // pos and direction follow it
	local_pos, local_dir:                      Vec3, // relative to the attached instance
}

// Returns the light's index, or -1 when full.
light_spawn_point :: proc(engine: ^Engine, light: PointLight) -> int {
	if engine.scene.point_light_count >= len(engine.scene.point_lights) {
		log.errorf("max point lights reached (%d)", len(engine.scene.point_lights))
		return -1
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	engine.scene.point_lights[engine.scene.point_light_count] = light
	engine.scene.point_light_count += 1
	return int(engine.scene.point_light_count) - 1
}

spawn_directional_light :: proc(engine: ^Engine, light: DirectionalLight) {
	if engine.scene.directional_light_count >= len(engine.scene.directional_lights) {
		log.errorf("max directional lights reached (%d)", len(engine.scene.directional_lights))
		return
	}
	engine.scene.directional_lights[engine.scene.directional_light_count] = light
	engine.scene.directional_light_count += 1
}

// Returns the light's index, or -1 when full.
spawn_spot_light :: proc(engine: ^Engine, light: SpotLight) -> int {
	if engine.scene.spot_light_count >= len(engine.scene.spot_lights) {
		log.errorf("max spot lights reached (%d)", len(engine.scene.spot_lights))
		return -1
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	engine.scene.spot_lights[engine.scene.spot_light_count] = light
	engine.scene.spot_light_count += 1
	return int(engine.scene.spot_light_count) - 1
}

// Makes the point light follow instance, keeping its current world position.
light_attach_point :: proc(engine: ^Engine, light_index: int, instance: InstanceHandle) {
	light := &engine.scene.point_lights[light_index]
	inverse := linalg.inverse(transform_to_matrix(instance_get(engine, instance).transform))
	light.attached = instance
	light.local_pos = (inverse * Vec4{light.pos.x, light.pos.y, light.pos.z, 1}).xyz
}

// Makes the spot light follow instance, keeping its current world position and direction.
light_attach_spot :: proc(engine: ^Engine, light_index: int, instance: InstanceHandle) {
	light := &engine.scene.spot_lights[light_index]
	inverse := linalg.inverse(transform_to_matrix(instance_get(engine, instance).transform))
	light.attached = instance
	light.local_pos = (inverse * Vec4{light.pos.x, light.pos.y, light.pos.z, 1}).xyz
	light.local_dir = linalg.normalize(
		(inverse * Vec4{light.direction.x, light.direction.y, light.direction.z, 0}).xyz,
	)
}

// Moves the lights attached to instance to its new world transform. The shadow plan sees the move
// through the light's cache key.
lights_follow :: proc(engine: ^Engine, instance: InstanceHandle, world: Transform) {
	m := transform_to_matrix(world)
	for &light in engine.scene.point_lights[:engine.scene.point_light_count] {
		if attached, ok := light.attached.?; !ok || attached != instance do continue
		light.pos = (m * Vec4{light.local_pos.x, light.local_pos.y, light.local_pos.z, 1}).xyz
	}
	for &light in engine.scene.spot_lights[:engine.scene.spot_light_count] {
		if attached, ok := light.attached.?; !ok || attached != instance do continue
		light.pos = (m * Vec4{light.local_pos.x, light.local_pos.y, light.local_pos.z, 1}).xyz
		light.direction = linalg.normalize((m * Vec4{light.local_dir.x, light.local_dir.y, light.local_dir.z, 0}).xyz)
	}
}

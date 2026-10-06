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
light_spawn_point :: proc(scene: ^Scene, light: PointLight) -> int {
	if scene.point_light_count >= len(scene.point_lights) {
		log.errorf("max point lights reached (%d)", len(scene.point_lights))
		return -1
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	scene.point_lights[scene.point_light_count] = light
	scene.point_light_count += 1
	return int(scene.point_light_count) - 1
}

// Returns the light's index, or -1 when full.
light_spawn_directional :: proc(scene: ^Scene, light: DirectionalLight) -> int {
	if scene.directional_light_count >= len(scene.directional_lights) {
		log.errorf("max directional lights reached (%d)", len(scene.directional_lights))
		return -1
	}
	scene.directional_lights[scene.directional_light_count] = light
	scene.directional_light_count += 1
	return int(scene.directional_light_count) - 1
}

// Returns the light's index, or -1 when full.
light_spawn_spot :: proc(scene: ^Scene, light: SpotLight) -> int {
	if scene.spot_light_count >= len(scene.spot_lights) {
		log.errorf("max spot lights reached (%d)", len(scene.spot_lights))
		return -1
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	scene.spot_lights[scene.spot_light_count] = light
	scene.spot_light_count += 1
	return int(scene.spot_light_count) - 1
}

// Makes the point light follow instance, keeping its current world position.
light_attach_point :: proc(scene: ^Scene, light_index: int, instance: InstanceHandle) {
	assert(
		light_index >= 0 && light_index < int(scene.point_light_count),
		"light_attach_point: no point light at index",
	)
	light := &scene.point_lights[light_index]
	inverse := linalg.inverse(transform_to_matrix(instance_get(scene, instance).transform))
	light.attached = instance
	light.local_pos = (inverse * Vec4{light.pos.x, light.pos.y, light.pos.z, 1}).xyz
}

// Makes the spot light follow instance, keeping its current world position and direction.
light_attach_spot :: proc(scene: ^Scene, light_index: int, instance: InstanceHandle) {
	assert(light_index >= 0 && light_index < int(scene.spot_light_count), "light_attach_spot: no spot light at index")
	light := &scene.spot_lights[light_index]
	inverse := linalg.inverse(transform_to_matrix(instance_get(scene, instance).transform))
	light.attached = instance
	light.local_pos = (inverse * Vec4{light.pos.x, light.pos.y, light.pos.z, 1}).xyz
	light.local_dir = linalg.normalize(
		(inverse * Vec4{light.direction.x, light.direction.y, light.direction.z, 0}).xyz,
	)
}

// Stops the lights attached to instance from following it. They keep their world position and
// direction, so their shadow cache keys don't change.
lights_detach :: proc(scene: ^Scene, instance: InstanceHandle) {
	for &light in scene.point_lights[:scene.point_light_count] {
		if attached, ok := light.attached.?; ok && attached == instance do light.attached = nil
	}
	for &light in scene.spot_lights[:scene.spot_light_count] {
		if attached, ok := light.attached.?; ok && attached == instance do light.attached = nil
	}
}

// Moves the lights attached to instance to its new world transform. The shadow plan sees the move
// through the light's cache key.
lights_follow :: proc(scene: ^Scene, instance: InstanceHandle, world: Transform) {
	m := transform_to_matrix(world)
	for &light in scene.point_lights[:scene.point_light_count] {
		if attached, ok := light.attached.?; !ok || attached != instance do continue
		light.pos = (m * Vec4{light.local_pos.x, light.local_pos.y, light.local_pos.z, 1}).xyz
	}
	for &light in scene.spot_lights[:scene.spot_light_count] {
		if attached, ok := light.attached.?; !ok || attached != instance do continue
		light.pos = (m * Vec4{light.local_pos.x, light.local_pos.y, light.local_pos.z, 1}).xyz
		light.direction = linalg.normalize((m * Vec4{light.local_dir.x, light.local_dir.y, light.local_dir.z, 0}).xyz)
	}
}

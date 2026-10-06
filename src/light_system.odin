package main

import "core:log"
import "core:math/linalg"
import gfx "veil:graphics"

LightSystem :: gfx.LightData

// Returns the light's index, or -1 when full.
light_spawn_point :: proc(lights: ^LightSystem, light: gfx.PointLight) -> int {
	if lights.point_light_count >= len(lights.point_lights) {
		log.errorf("max point lights reached (%d)", len(lights.point_lights))
		return -1
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	lights.point_lights[lights.point_light_count] = light
	lights.point_light_count += 1
	return int(lights.point_light_count) - 1
}

// Returns the light's index, or -1 when full.
light_spawn_directional :: proc(lights: ^LightSystem, light: gfx.DirectionalLight) -> int {
	if lights.directional_light_count >= len(lights.directional_lights) {
		log.errorf("max directional lights reached (%d)", len(lights.directional_lights))
		return -1
	}
	lights.directional_lights[lights.directional_light_count] = light
	lights.directional_light_count += 1
	return int(lights.directional_light_count) - 1
}

// Returns the light's index, or -1 when full.
light_spawn_spot :: proc(lights: ^LightSystem, light: gfx.SpotLight) -> int {
	if lights.spot_light_count >= len(lights.spot_lights) {
		log.errorf("max spot lights reached (%d)", len(lights.spot_lights))
		return -1
	}

	if light.constant < 1.0 {
		log.warnf("constant should be >= 1.0 to avoid division by zero, got %f", light.constant)
	}

	lights.spot_lights[lights.spot_light_count] = light
	lights.spot_light_count += 1
	return int(lights.spot_light_count) - 1
}

LightKind :: enum {
	Point,
	Spot,
}

// A light that follows an entity: world_update places it at local_pos (and aims a spot along
// local_dir) in the entity's space. Dropped once the entity is destroyed; the light stays put.
LightLink :: struct {
	kind:                 LightKind,
	index:                int,
	entity:               EntityHandle,
	local_pos, local_dir: gfx.Vec3,
}

// Makes the point light follow entity, keeping its current world position.
light_attach_point :: proc(w: ^World, light_index: int, entity: EntityHandle) {
	assert(
		light_index >= 0 && light_index < int(w.lights.point_light_count),
		"light_attach_point: no point light at index",
	)
	light := w.lights.point_lights[light_index]
	inverse := linalg.inverse(entity_get(w, entity).global_transform)
	append(
		&w.light_links,
		LightLink {
			kind = .Point,
			index = light_index,
			entity = entity,
			local_pos = (inverse * gfx.Vec4{light.pos.x, light.pos.y, light.pos.z, 1}).xyz,
		},
	)
}

// Makes the spot light follow entity, keeping its current world position and direction.
light_attach_spot :: proc(w: ^World, light_index: int, entity: EntityHandle) {
	assert(
		light_index >= 0 && light_index < int(w.lights.spot_light_count),
		"light_attach_spot: no spot light at index",
	)
	light := w.lights.spot_lights[light_index]
	inverse := linalg.inverse(entity_get(w, entity).global_transform)
	append(
		&w.light_links,
		LightLink {
			kind = .Spot,
			index = light_index,
			entity = entity,
			local_pos = (inverse * gfx.Vec4{light.pos.x, light.pos.y, light.pos.z, 1}).xyz,
			local_dir = (inverse * gfx.Vec4{light.direction.x, light.direction.y, light.direction.z, 0}).xyz,
		},
	)
}

// Moves each attached light to its entity's global_transform. The shadow plan sees the move
// through the light's cache key.
lights_follow :: proc(w: ^World) {
	#reverse for link, i in w.light_links {
		if !entity_alive(w, link.entity) {
			unordered_remove(&w.light_links, i)
			continue
		}
		m := entity_get(w, link.entity).global_transform
		pos := (m * gfx.Vec4{link.local_pos.x, link.local_pos.y, link.local_pos.z, 1}).xyz
		switch link.kind {
		case .Point:
			w.lights.point_lights[link.index].pos = pos
		case .Spot:
			light := &w.lights.spot_lights[link.index]
			light.pos = pos
			light.direction = linalg.normalize(
				(m * gfx.Vec4{link.local_dir.x, link.local_dir.y, link.local_dir.z, 0}).xyz,
			)
		}
	}
}

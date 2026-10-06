package main

import "core:math/linalg"
import gfx "veil:graphics"
import "veil:handles"

// Entity slots double as draw ids.
MAX_ENTITIES :: gfx.MAX_DRAWS

World :: struct {
	entities:      handles.Pool(Entity),
	active_camera: EntityHandle,
	selected:      EntityHandle,
	pending:       [dynamic]EntityHandle, // marked by entity_destroy, freed by world_flush
	lights:        gfx.LightData,
	light_links:   [dynamic]LightLink,
	background:    gfx.Background,
	time:          f32, // seconds of game time; world_update advances it
	delta_time:    f32,
}

world_create :: proc(w: ^World) {
	w.entities = handles.pool_init(MAX_ENTITIES, Entity)
	w.background = gfx.Vec4{0, 0, 0, 1}
	w.lights.ambient_light = {
		color      = {1, 1, 1, 1},
		brightness = 0.03,
	}
}

world_destroy :: proc(w: ^World) {
	handles.pool_destroy(&w.entities)
	delete(w.pending)
	delete(w.light_links)
	w^ = {}
}

// Advances game time by dt, recomputes every global_transform from the roots down, then moves the
// attached lights.
// TODO: this walks every entity every frame, and draw_history_sync then compares every draw. Fine
// at 4k entities; measure near MAX_ENTITIES (32k) with a benchmark scene before relying on it, and
// add dirty flags if it shows up.
world_update :: proc(w: ^World, dt: f32) {
	w.delta_time = dt
	w.time += dt
	for &e, i in w.entities.values[:w.entities.count] {
		if !handles.pool_is_alive(&w.entities, handles.Index(i)) || e.parent != INVALID_ENTITY do continue
		entity_propagate(w, &e, linalg.MATRIX4F32_IDENTITY)
	}
	lights_follow(w)
}

@(private = "file")
entity_propagate :: proc(w: ^World, e: ^Entity, parent_global: gfx.Mat4x4) {
	e.global_transform = parent_global * gfx.transform_to_matrix(e.transform)
	for c := e.first_child; c != INVALID_ENTITY; {
		child := entity_get(w, c)
		entity_propagate(w, child, e.global_transform)
		c = child.next_sibling
	}
}

// Frees every entity marked since the last flush, and its descendants. Handles to them go stale.
world_flush :: proc(w: ^World) {
	for h in w.pending {
		if !handles.pool_is_valid(&w.entities, h) do continue // freed with a marked ancestor
		entity_unlink(w, h)
		entity_free_tree(w, h)
	}
	clear(&w.pending)
}

// Removes h from its parent's child list.
@(private = "file")
entity_unlink :: proc(w: ^World, h: EntityHandle) {
	e := entity_get(w, h)
	if e.parent == INVALID_ENTITY do return
	link := &entity_get(w, e.parent).first_child
	for link^ != h do link = &entity_get(w, link^).next_sibling
	link^ = e.next_sibling
}

@(private = "file")
entity_free_tree :: proc(w: ^World, h: EntityHandle) {
	for c := entity_get(w, h).first_child; c != INVALID_ENTITY; {
		next := entity_get(w, c).next_sibling
		entity_free_tree(w, c)
		c = next
	}
	handles.pool_free(&w.entities, h)
}

// The flat view of the world the renderer draws. draws uses allocator.
world_extract :: proc(w: ^World, allocator := context.temp_allocator) -> gfx.FramePacket {
	draws := make([dynamic]gfx.Draw, 0, handles.pool_live_count(&w.entities), allocator)
	for e, i in w.entities.values[:w.entities.count] {
		if !handles.pool_is_alive(&w.entities, handles.Index(i)) do continue
		if .Renderable not_in e.flags || .Pending_Destroy in e.flags do continue
		append(
			&draws,
			gfx.Draw {
				id = u32(i),
				model = e.model,
				world = e.global_transform,
				casts_shadow = .Casts_Shadow in e.flags,
			},
		)
	}
	return {
		time = w.time,
		delta_time = w.delta_time,
		draws = draws[:],
		camera = world_camera(w),
		lights = &w.lights,
		background = w.background,
	}
}

// The active camera in world space, from its entity's global_transform. A default camera when the
// active camera entity is gone.
world_camera :: proc(w: ^World) -> gfx.Camera {
	if !entity_alive(w, w.active_camera) do return gfx.camera_create()
	e := entity_get(w, w.active_camera)
	camera := e.camera
	x, y, z := gfx.matrix_axes(e.global_transform)
	camera.position = gfx.matrix_translation(e.global_transform)
	camera.right = linalg.normalize(x)
	camera.up = linalg.normalize(y)
	camera.front = -linalg.normalize(z)
	return camera
}

// The live entity drawn under pos, from the last frame's packet.
world_pick :: proc(engine: ^gfx.Engine, w: ^World, pos: gfx.Vec2) -> EntityHandle {
	id, hit := gfx.pick(engine, world_camera(w), pos)
	if !hit do return INVALID_ENTITY
	h := EntityHandle{handles.Index(id), w.entities.generations[id]}
	return h if entity_alive(w, h) else INVALID_ENTITY
}

package main

import "core:log"
import "core:math/linalg"

import gfx "veil:graphics"
import "veil:handles"

EntityFlag :: enum {
	Renderable,
	Casts_Shadow,
	Camera,
	Pending_Destroy,
}

Entity :: struct {
	flags:                             bit_set[EntityFlag],
	transform:                         gfx.Transform, // local: relative to parent, else world
	global_transform:                  gfx.Mat4x4, // world; computed by world_update
	parent, first_child, next_sibling: EntityHandle,
	model:                             gfx.ModelHandle, // used if .Renderable
	camera:                            gfx.Camera, // used if .Camera; position and yaw/pitch drive transform
}

EntityHandle :: handles.Handle(Entity)
INVALID_ENTITY :: EntityHandle{}

EntityDesc :: struct {
	flags:     bit_set[EntityFlag],
	transform: gfx.Transform, // the zero value means identity
	model:     gfx.ModelHandle,
	camera:    gfx.Camera,
}

// What entity_get returns for a stale handle. Reset on every return, so writes through it are lost.
@(private = "file")
nil_entity: Entity

// Returns INVALID_ENTITY when the world is full or parent is stale. global_transform is valid at once.
entity_spawn :: proc(w: ^World, desc: EntityDesc, parent := INVALID_ENTITY) -> EntityHandle {
	if handles.pool_live_count(&w.entities) >= MAX_ENTITIES {
		log.errorf("entity_spawn: world full (%d)", MAX_ENTITIES)
		return INVALID_ENTITY
	}
	if parent != INVALID_ENTITY && !entity_alive(w, parent) {
		log.errorf("entity_spawn: parent is stale or being destroyed")
		return INVALID_ENTITY
	}
	assert(.Renderable not_in desc.flags || desc.model != gfx.INVALID_MODEL, "renderable entity without a model")

	e := Entity {
		flags     = desc.flags - {.Pending_Destroy},
		transform = desc.transform if desc.transform != {} else gfx.transform_create(),
		model     = desc.model,
		camera    = desc.camera,
		parent    = parent,
	}
	parent_global := linalg.MATRIX4F32_IDENTITY
	if parent != INVALID_ENTITY {
		p := entity_get(w, parent)
		parent_global = p.global_transform
		e.next_sibling = p.first_child
	}
	e.global_transform = parent_global * gfx.transform_to_matrix(e.transform)
	handle := handles.pool_alloc(&w.entities, e)
	if parent != INVALID_ENTITY do entity_get(w, parent).first_child = handle
	return handle
}

entity_spawn_model :: proc(
	w: ^World,
	model: gfx.ModelHandle,
	transform: gfx.Transform,
	casts_shadow := true,
	parent := INVALID_ENTITY,
) -> EntityHandle {
	flags: bit_set[EntityFlag] = {.Renderable}
	if casts_shadow do flags += {.Casts_Shadow}
	return entity_spawn(w, {flags = flags, transform = transform, model = model}, parent)
}

// The transform comes from the camera's position and yaw/pitch.
entity_spawn_camera :: proc(w: ^World, camera: gfx.Camera, parent := INVALID_ENTITY) -> EntityHandle {
	return entity_spawn(w, {flags = {.Camera}, transform = camera_rig_transform(camera), camera = camera}, parent)
}

// A root at transform with one child per part. Moving the root moves every part; destroying it
// destroys them all.
entity_spawn_parts :: proc(
	w: ^World,
	parts: []gfx.ModelPart,
	transform: gfx.Transform,
	casts_shadow := true,
) -> EntityHandle {
	root := entity_spawn(w, {transform = transform})
	if root == INVALID_ENTITY do return root
	for part in parts do entity_spawn_model(w, part.model, part.transform, casts_shadow, parent = root)
	return root
}

// Never nil: a stale handle gets a zeroed stand-in.
entity_get :: proc(w: ^World, h: EntityHandle) -> ^Entity {
	if !handles.pool_is_valid(&w.entities, h) {
		nil_entity = {}
		return &nil_entity
	}
	return handles.pool_get(&w.entities, h)
}

// Live and not marked for destruction.
entity_alive :: proc(w: ^World, h: EntityHandle) -> bool {
	return handles.pool_is_valid(&w.entities, h) && .Pending_Destroy not_in entity_get(w, h).flags
}

// Marks h; world_flush frees it and its descendants. No-op for a stale or already marked handle.
entity_destroy :: proc(w: ^World, h: EntityHandle) {
	if !entity_alive(w, h) do return
	entity_get(w, h).flags += {.Pending_Destroy}
	append(&w.pending, h)
}

// Moves child under parent (INVALID_ENTITY for a root), keeping its world transform.
// TODO: implement. Steps:
// - reject a stale or pending child/parent, and a parent that is child or one of its descendants
//   (walk up from parent through .parent);
// - unlink child from its old parent's first_child/next_sibling list (as world.odin's entity_unlink);
// - link it as parent's first_child, set child.parent;
// - keep the world transform: child.transform = inverse(parent.global_transform) * child.global_transform
//   (identity parent for a root), as entity_set_world_transform does.
entity_set_parent :: proc(w: ^World, child, parent: EntityHandle) {
	unimplemented("entity_set_parent")
}

entity_world_transform :: proc(w: ^World, h: EntityHandle) -> gfx.Transform {
	return gfx.transform_from_matrix(entity_get(w, h).global_transform)
}

// Sets the local transform that puts h at world. Updates h's global_transform now; its children
// follow at the next world_update.
entity_set_world_transform :: proc(w: ^World, h: EntityHandle, world: gfx.Transform) {
	e := entity_get(w, h)
	world_matrix := gfx.transform_to_matrix(world)
	e.transform = world
	if e.parent != INVALID_ENTITY {
		parent_global := entity_get(w, e.parent).global_transform
		e.transform = gfx.transform_from_matrix(linalg.inverse(parent_global) * world_matrix)
	}
	e.global_transform = world_matrix
}

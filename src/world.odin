package main

import gfx "graphics"
import "handles"

MAX_ENTITIES :: 1024

// A game object. A live entity's render_instance is always a live, unmarked instance, or
// INVALID_INSTANCE when it has none.
Entity :: struct {
	render_instance: gfx.InstanceHandle,
	pending_destroy: bool, // marked by entity_destroy: skip it; world_sweep frees it
}

EntityHandle :: handles.Handle(Entity)

World :: struct {
	entities:        handles.Pool(Entity),
	pending_destroy: [dynamic]EntityHandle,
}

world_create :: proc(world: ^World) {
	world.entities = handles.pool_init(MAX_ENTITIES, Entity)
}

world_destroy :: proc(world: ^World) {
	handles.pool_destroy(&world.entities)
	delete(world.pending_destroy)
}

entity_spawn :: proc(world: ^World, entity: Entity) -> EntityHandle {
	return handles.pool_alloc(&world.entities, entity)
}

entity_get :: proc(world: ^World, handle: EntityHandle) -> ^Entity {
	return handles.pool_get(&world.entities, handle)
}

// Marks the entity and destroys its render subtree. Any other entity whose render instance was in
// that subtree is marked too, so no live entity is left with a dead render instance.
entity_destroy :: proc(world: ^World, scene: ^gfx.Scene, handle: EntityHandle) {
	entity := entity_get(world, handle)
	if entity.pending_destroy do return
	entity_mark(world, handle)
	if entity.render_instance != gfx.INVALID_INSTANCE && !gfx.instance_is_pending(scene, entity.render_instance) {
		gfx.instance_destroy(scene, entity.render_instance)
	}

	// The scene only knows instance links, so find the owners of whatever it marked.
	for &other, i in world.entities.values {
		if !handles.pool_is_alive(&world.entities, handles.Index(i)) || other.pending_destroy do continue
		if other.render_instance == gfx.INVALID_INSTANCE do continue
		if gfx.instance_is_pending(scene, other.render_instance) {
			entity_mark(world, EntityHandle{handles.Index(i), world.entities.generations[i]})
		}
	}
}

@(private = "file")
entity_mark :: proc(world: ^World, handle: EntityHandle) {
	entity_get(world, handle).pending_destroy = true
	append(&world.pending_destroy, handle)
}

// Frees the entities entity_destroy marked. Call once per frame, after gfx.engine_render (which
// sweeps the scene).
world_sweep :: proc(world: ^World) {
	for handle in world.pending_destroy do handles.pool_free(&world.entities, handle)
	clear(&world.pending_destroy)
}

// Example: a turret entity whose instance hangs off a ship entity's instance. Destroying the ship
// takes the turret with it, on both sides.
world_example :: proc(world: ^World, scene: ^gfx.Scene, ship_model, turret_model: gfx.ModelHandle) {
	ship_instance := gfx.instance_spawn(scene, ship_model, gfx.transform_create())
	turret_instance := gfx.instance_spawn(
		scene,
		turret_model,
		gfx.transform_create(translation = {0, 1, 0}),
		parent = ship_instance,
	)
	ship := entity_spawn(world, {render_instance = ship_instance})
	turret := entity_spawn(world, {render_instance = turret_instance})

	entity_destroy(world, scene, ship)

	// Both are marked right away: game code skips them, the renderer no longer draws them.
	assert(entity_get(world, turret).pending_destroy)
	assert(gfx.instance_is_pending(scene, turret_instance))

	// Then, in the frame loop:
	//   gfx.engine_render(engine, scene, ...)  frees the instances (scene sweep)
	//   world_sweep(world)              frees the entities (game sweep)
}

package graphics

import "core:log"
import "core:math"
import "core:math/linalg"

// What fills the pixels no geometry covers.
Background :: union #no_nil {
	Vec4, // clear color: the pass clears to it, no draw
	TextureHandle, // sky cube: one fullscreen draw
}

Scene :: struct {
	active_camera_name:      string,
	ambient_light:           AmbientLight,
	background:              Background,
	point_lights:            [MAX_POINT_LIGHTS]PointLight,
	directional_lights:      [MAX_DIRECTIONAL_LIGHTS]DirectionalLight,
	spot_lights:             [MAX_SPOT_LIGHTS]SpotLight,
	point_light_count:       u32,
	directional_light_count: u32,
	spot_light_count:        u32,
	instances:               Pool(Instance),
	instance_links:          []InstanceLink, // by pool slot
	instance_changes:        [dynamic]InstanceChange, // since the last recorded frame
	pending_destroy:         [dynamic]InstanceHandle, // marked by instance_destroy, freed by the sweep
	selection:               Selection,
}

scene_create :: proc(scene: ^Scene) {
	scene.instances = pool_init(MAX_MODEL_INSTANCES, Instance)
	scene.instance_links = make([]InstanceLink, MAX_MODEL_INSTANCES)
}

scene_destroy :: proc(scene: ^Scene) {
	for &link in scene.instance_links do delete(link.children)
	delete(scene.instance_links)
	pool_destroy(&scene.instances)
	delete(scene.instance_changes)
	delete(scene.pending_destroy)
}

InstanceHandle :: Handle(Instance)

INVALID_INSTANCE :: InstanceHandle{}

Instance :: struct {
	model:        ModelHandle, // INVALID_MODEL for a group root: no mesh, only a transform
	bounds:       BoundingSphere, // model space, copied from the model at spawn; radius 0 for a group root
	transform:       Transform, // world space
	casts_shadow:    bool,
	pending_destroy: bool, // marked by instance_destroy: skipped everywhere, freed by the sweep
}

// Where an instance sits in the hierarchy. Kept beside the pool (Scene.instance_links, one per
// slot), because Instance can't hold Handle(Instance).
InstanceLink :: struct {
	parent:   Maybe(InstanceHandle),
	local:    Transform, // relative to parent; same as the world transform without a parent
	children: [dynamic]InstanceHandle,
}

MAX_MODEL_INSTANCES :: 4096

// What an instance change needs to know about an instance on one side of the change.
InstanceState :: struct {
	bounds:       BoundingSphere, // world space
	casts_shadow: bool,
}

InstanceChangeKind :: enum {
	Spawn, // old is unused
	Update,
	Despawn, // new is unused
}

// One spawn, setter or destroy call on an instance.
InstanceChange :: struct {
	kind:     InstanceChangeKind,
	instance: InstanceHandle,
	old:      InstanceState,
	new:      InstanceState,
}

// Spawns a group root at transform and one child instance per part. Moving the root moves every
// part. Returns the part handles in part order.
instance_spawn_parts :: proc(
	engine: ^Engine,
	parts: []ModelPart,
	transform: Transform,
	casts_shadow := true,
	allocator := context.temp_allocator,
) -> []InstanceHandle {
	handles := make([]InstanceHandle, len(parts), allocator)
	root := instance_alloc(&engine.scene, Instance{model = INVALID_MODEL, transform = transform})
	instance_link(&engine.scene, root).local = transform
	for part, i in parts {
		handles[i] = instance_spawn(engine, part.model, part.transform, casts_shadow, parent = root)
	}
	return handles
}

// Returns a copy. Change an instance through the setters, so the change is recorded.
instance_get :: proc(scene: ^Scene, handle: InstanceHandle) -> Instance {
	return pool_get(&scene.instances, handle)^
}

instance_link :: proc(scene: ^Scene, handle: InstanceHandle) -> ^InstanceLink {
	assert(pool_is_valid(&scene.instances, handle))
	return &scene.instance_links[handle.index]
}

// Sets the world transform. Children and attached lights follow.
instance_set_transform :: proc(scene: ^Scene, handle: InstanceHandle, transform: Transform) {
	link := instance_link(scene, handle)
	link.local = transform
	if parent, ok := link.parent.?; ok {
		parent_world := transform_to_matrix(instance_get(scene, parent).transform)
		link.local = transform_from_matrix(linalg.inverse(parent_world) * transform_to_matrix(transform))
	}
	instance := instance_get(scene, handle)
	instance.transform = transform
	instance_replace(scene, handle, instance)
	instance_update_dependents(scene, handle)
}

// Makes child follow parent, keeping the child's world transform. Asserts on a cycle.
instance_attach :: proc(scene: ^Scene, child, parent: InstanceHandle) {
	assert(
		!pool_get(&scene.instances, child).pending_destroy && !pool_get(&scene.instances, parent).pending_destroy,
		"instance_attach: instance is being destroyed",
	)
	for p := Maybe(InstanceHandle)(parent); p != nil; p = instance_link(scene, p.?).parent {
		assert(p.? != child, "instance_attach: parent is the child or one of its descendants")
	}
	instance_detach(scene, child)
	append(&instance_link(scene, parent).children, child)
	instance_link(scene, child).parent = parent
	instance_set_transform(scene, child, instance_get(scene, child).transform) // recompute local
}

// Removes child from its parent, keeping its world transform. No-op without a parent.
instance_detach :: proc(scene: ^Scene, child: InstanceHandle) {
	link := instance_link(scene, child)
	parent, ok := link.parent.?
	if !ok do return
	siblings := &instance_link(scene, parent).children
	for c, i in siblings do if c == child {
		ordered_remove(siblings, i)
		break
	}
	link.parent = nil
	link.local = instance_get(scene, child).transform
}

// Recomputes the world transform of each child from its local, recursively, and moves the lights
// attached to handle.
@(private = "file")
instance_update_dependents :: proc(scene: ^Scene, handle: InstanceHandle) {
	instance := instance_get(scene, handle)
	world := transform_to_matrix(instance.transform)
	for child_handle in instance_link(scene, handle).children {
		child := instance_get(scene, child_handle)
		child.transform = transform_from_matrix(world * transform_to_matrix(instance_link(scene, child_handle).local))
		instance_replace(scene, child_handle, child)
		instance_update_dependents(scene, child_handle)
	}
	lights_follow(scene, handle, instance.transform)
}

instance_set_casts_shadow :: proc(scene: ^Scene, handle: InstanceHandle, casts_shadow: bool) {
	instance := instance_get(scene, handle)
	instance.casts_shadow = casts_shadow
	instance_replace(scene, handle, instance)
}

// The one write path for a live instance; records the change.
@(private = "file")
instance_replace :: proc(scene: ^Scene, handle: InstanceHandle, instance: Instance) {
	slot := pool_get(&scene.instances, handle)
	assert(!slot.pending_destroy, "instance is being destroyed")
	old := slot^
	slot^ = instance
	instance_change_record(scene, .Update, handle, old, instance)
}

// Marks handle and its descendants for destruction. They stop drawing and picking at once, and
// instance_sweep_destroyed frees their slots at the end of the frame. Records a Despawn change for
// each, clears the selection if it points at one, and detaches the lights following one, leaving
// them where they are. No-op for an instance that is already marked.
instance_destroy :: proc(scene: ^Scene, handle: InstanceHandle) {
	if pool_get(&scene.instances, handle).pending_destroy do return
	// A parent that stays alive must not reach a marked child when it moves.
	instance_detach(scene, handle)
	instance_mark(scene, handle)
}

@(private = "file")
instance_mark :: proc(scene: ^Scene, handle: InstanceHandle) {
	slot := pool_get(&scene.instances, handle)
	if slot.pending_destroy do return
	slot.pending_destroy = true
	append(&scene.pending_destroy, handle)
	instance_change_record(scene, .Despawn, handle, slot^, {})
	if selected_instance(scene) == handle do scene.selection = nil
	lights_detach(scene, handle)
	for child in instance_link(scene, handle).children do instance_mark(scene, child)
}

// True once instance_destroy has marked the instance, and after the sweep has freed it. Lets the
// owner of a handle notice that its instance went away through a destroyed parent.
instance_is_pending :: proc(scene: ^Scene, handle: InstanceHandle) -> bool {
	return !pool_is_valid(&scene.instances, handle) || pool_get(&scene.instances, handle).pending_destroy
}

// Frees the slots instance_destroy marked. Runs every frame once the renderer is done with the
// scene, drawn or skipped: the Despawn changes already carry what the shadow cache needs.
instance_sweep_destroyed :: proc(scene: ^Scene) {
	for handle in scene.pending_destroy do pool_free(&scene.instances, handle)
	clear(&scene.pending_destroy)
}

// World-space bounding sphere: the model's sphere moved by the transform, radius scaled by the
// largest axis scale.
instance_world_sphere :: proc(instance: Instance) -> BoundingSphere {
	center := transform_point(instance.transform, instance.bounds.center)
	scale := transform_global_scale(instance.transform)
	max_scale := max(math.abs(scale.x), math.abs(scale.y), math.abs(scale.z))
	return BoundingSphere{center, instance.bounds.radius * max_scale}
}

@(private = "file")
instance_state :: proc(scene: ^Scene, instance: Instance) -> InstanceState {
	return InstanceState{bounds = instance_world_sphere(instance), casts_shadow = instance.casts_shadow}
}

// Appends one change per call, never merged. old is unused for a spawn, new for a despawn.
@(private = "file")
instance_change_record :: proc(
	scene: ^Scene,
	kind: InstanceChangeKind,
	handle: InstanceHandle,
	old, new: Instance,
) {
	change := InstanceChange {
		kind     = kind,
		instance = handle,
	}
	if kind != .Spawn do change.old = instance_state(scene, old)
	if kind != .Despawn do change.new = instance_state(scene, new)
	append(&scene.instance_changes, change)
}

instance_spawn :: proc(
	engine: ^Engine,
	model: ModelHandle,
	transform: Transform, // relative to parent when given, else world
	casts_shadow := true,
	parent: Maybe(InstanceHandle) = nil,
) -> InstanceHandle {
	if model == INVALID_MODEL {
		log.errorf("spawn: refusing to spawn an instance of an invalid model handle")
		return INVALID_INSTANCE
	}
	instance := Instance {
		model        = model,
		bounds       = pool_get(&engine.model_system.models, model).bounds,
		transform    = transform,
		casts_shadow = casts_shadow,
	}
	if p, ok := parent.?; ok {
		assert(!instance_get(&engine.scene, p).pending_destroy, "spawn: parent is being destroyed")
		instance.transform = transform_from_matrix(
			transform_to_matrix(instance_get(&engine.scene, p).transform) * transform_to_matrix(transform),
		)
	}
	handle := instance_alloc(&engine.scene, instance)
	link := instance_link(&engine.scene, handle)
	link.local = transform
	if p, ok := parent.?; ok {
		link.parent = p
		append(&instance_link(&engine.scene, p).children, handle)
	}
	return handle
}

@(private = "file")
instance_alloc :: proc(scene: ^Scene, instance: Instance) -> InstanceHandle {
	handle := pool_alloc(&scene.instances, instance)
	// A reused slot may hold a freed instance's link; keep its children allocation.
	link := &scene.instance_links[handle.index]
	clear(&link.children)
	link.parent = nil
	link.local = instance.transform
	instance_change_record(scene, .Spawn, handle, {}, instance)
	return handle
}

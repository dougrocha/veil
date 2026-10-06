package graphics

import "core:slice"

// Every shadow caster in the scene, built once and filtered per shadow view, so a view doesn't walk
// and sort the whole scene. One id per mesh of each live, shadow-casting instance, grouped into one
// run per mesh (by vertex buffer, ids in slot order). Transforms are read from the scene each frame,
// so the list only changes with the set of casters: spawns, despawns and casts_shadow toggles within
// an epoch, or a new epoch. Model meshes never change once added, so the mesh pointers stay valid.
ShadowCasters :: struct {
	scene_epoch:    u64, // the Scene.epoch the list was built against; 0 before the first build
	runs:           [dynamic]DrawRun, // ids slice into ids
	ids:            [dynamic]u32,
	bounds:         [dynamic]CasterBounds, // parallel to ids; this frame's once bounds_current
	bounds_current: bool, // cleared every frame by shadow_casters_sync, filled by the first filter
}

// The world-space volumes the culling tests check, computed once per frame and shared by every view.
CasterBounds :: struct {
	sphere: BoundingSphere, // the instance's
	aabb:   AABB, // the mesh's
}

shadow_casters_destroy :: proc(casters: ^ShadowCasters) {
	delete(casters.runs)
	delete(casters.ids)
	delete(casters.bounds)
}

// Rebuilds the list when the scene's casters changed since the last recorded frame. Call once per
// recorded frame, before scene.instance_changes is cleared, shadow passes on or off.
shadow_casters_sync :: proc(casters: ^ShadowCasters, view: SceneView, scene: ^Scene) {
	casters.bounds_current = false // transforms may have changed
	if casters.scene_epoch == scene.epoch && !caster_set_changed(scene.instance_changes[:]) do return
	casters.scene_epoch = scene.epoch

	items := make([dynamic]DrawItem, context.temp_allocator)
	for instance, slot_i in view.instances.values {
		if !pool_is_alive(view.instances, Index(slot_i)) || instance.pending_destroy do continue
		if instance.model == INVALID_MODEL || !instance.casts_shadow do continue
		model := pool_get(view.models, instance.model)
		for &mesh in model.meshes do append(&items, DrawItem{mesh = &mesh, instance = u32(slot_i)})
	}
	// By vertex buffer slot rather than mesh pointer, so the order doesn't follow heap addresses.
	slice.sort_by(items[:], proc(a, b: DrawItem) -> bool {
		ka, kb := a.mesh.vertex_buffer.handle.index, b.mesh.vertex_buffer.handle.index
		if ka != kb do return ka < kb
		return a.instance < b.instance
	})

	clear(&casters.runs)
	resize(&casters.ids, len(items))
	resize(&casters.bounds, len(items))
	for item, i in items do casters.ids[i] = item.instance
	start := 0
	for i in 1 ..= len(items) {
		if i < len(items) && items[i].mesh == items[start].mesh do continue
		append(&casters.runs, DrawRun{mesh = items[start].mesh, ids = casters.ids[start:i]})
		start = i
	}
}

// The casters a shadow view draws, temp-allocated, in list order. An id is kept when its instance's
// bounding sphere and its mesh's AABB both pass at least one of frustums (the culling rules of
// build_draw_list). skip_near ignores the near plane, for passes that clamp depth (directional
// cascades). Transparent meshes cast solid shadows, like the rest (as in Bevy; opt out per instance
// with casts_shadow).
shadow_casters_filter :: proc(
	casters: ^ShadowCasters,
	instances: ^Pool(Instance),
	frustums: []Frustum,
	skip_near: bool,
) -> []DrawRun {
	if !casters.bounds_current {
		entry := 0
		for run in casters.runs {
			for id in run.ids {
				instance := &instances.values[id]
				casters.bounds[entry] = {
					sphere = sphere_to_global(instance.bounds, instance.transform),
					aabb   = aabb_to_global(run.mesh.bounds, instance.transform),
				}
				entry += 1
			}
		}
		casters.bounds_current = true
	}

	runs := make([dynamic]DrawRun, 0, len(casters.runs), context.temp_allocator)
	ids := make([]u32, len(casters.ids), context.temp_allocator)
	entry, count := 0, 0
	for run in casters.runs {
		start := count
		for id in run.ids {
			bounds := &casters.bounds[entry]
			entry += 1
			for frustum in frustums {
				if !global_sphere_is_on_frustum(frustum, bounds.sphere, skip_near) do continue
				if !global_aabb_is_on_frustum(frustum, bounds.aabb, skip_near) do continue
				ids[count] = id
				count += 1
				break
			}
		}
		if count > start do append(&runs, DrawRun{mesh = run.mesh, ids = ids[start:count]})
	}
	return runs[:]
}

// Whether any change adds or removes a caster. Updates that keep casts_shadow only move one.
@(private = "file")
caster_set_changed :: proc(changes: []InstanceChange) -> bool {
	for change in changes {
		if change.kind != .Update || change.old.casts_shadow != change.new.casts_shadow do return true
	}
	return false
}

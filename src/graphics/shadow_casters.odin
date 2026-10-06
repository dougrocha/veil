package graphics

import "core:slice"

// Every shadow caster in the input, built once and filtered per shadow view, so a view doesn't walk
// and sort every draw. One id per mesh of each live, shadow-casting draw, grouped into one run per
// mesh (by vertex buffer, ids in order). Transforms are read from the draw history each frame,
// so the list only changes with the set of casters: spawns, despawns and casts_shadow toggles. Model
// meshes never change once added, so the mesh pointers stay valid.
ShadowCasters :: struct {
	built:          bool, // false before the first build
	runs:           [dynamic]DrawRun, // ids slice into ids
	ids:            [dynamic]u32,
	bounds:         [dynamic]CasterBounds, // parallel to ids; this frame's once bounds_current
	bounds_current: bool, // cleared every frame by shadow_casters_sync, filled by the first filter
}

// The world-space volumes the culling tests check, computed once per frame and shared by every view.
CasterBounds :: struct {
	sphere: BoundingSphere, // the draw's
	aabb:   AABB, // the mesh's
}

shadow_casters_destroy :: proc(casters: ^ShadowCasters) {
	delete(casters.runs)
	delete(casters.ids)
	delete(casters.bounds)
}

// Rebuilds the list when the casters changed since the last recorded frame. Call once per recorded
// frame, before the draw changes are cleared, shadow passes on or off.
shadow_casters_sync :: proc(casters: ^ShadowCasters, view: DrawInput, changes: []DrawChange) {
	casters.bounds_current = false // transforms may have changed
	if casters.built && !caster_set_changed(changes) do return
	casters.built = true

	items := make([dynamic]DrawItem, context.temp_allocator)
	for record, id in view.draws {
		if record.model == INVALID_MODEL || !record.casts_shadow do continue
		model := pool_get(view.models, record.model)
		for &mesh in model.meshes do append(&items, DrawItem{mesh = &mesh, id = u32(id)})
	}
	slice.sort_by(items[:], draw_item_less)

	clear(&casters.runs)
	resize(&casters.ids, len(items))
	resize(&casters.bounds, len(items))
	for item, i in items do casters.ids[i] = item.id
	start := 0
	for i in 1 ..= len(items) {
		if i < len(items) && items[i].mesh == items[start].mesh do continue
		append(&casters.runs, DrawRun{mesh = items[start].mesh, ids = casters.ids[start:i]})
		start = i
	}
}

// The casters a shadow view draws, temp-allocated, in list order. An id is kept when its draw's
// bounding sphere and its mesh's AABB both pass at least one of frustums (the culling rules of
// build_draw_list). skip_near ignores the near plane, for passes that clamp depth (directional
// cascades). Transparent meshes cast solid shadows, like the rest (as in Bevy; opt out per draw
// with casts_shadow).
shadow_casters_filter :: proc(
	casters: ^ShadowCasters,
	draws: []DrawRecord,
	frustums: []Frustum,
	skip_near: bool,
) -> []DrawRun {
	if !casters.bounds_current {
		entry := 0
		for run in casters.runs {
			for id in run.ids {
				record := &draws[id]
				casters.bounds[entry] = {
					sphere = sphere_to_global(record.bounds, record.world),
					aabb   = aabb_to_global(run.mesh.bounds, record.world),
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
caster_set_changed :: proc(changes: []DrawChange) -> bool {
	for change in changes {
		if change.kind != .Update || change.old.casts_shadow != change.new.casts_shadow do return true
	}
	return false
}

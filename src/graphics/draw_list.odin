package graphics

import "core:math/linalg"
import "core:slice"

// What a draw list is built from: the scene side of the engine, read-only.
SceneView :: struct {
	instances: ^Pool(Instance),
	models:    ^Pool(Model),
	materials: ^Pool(Material),
}

DrawListKind :: enum {
	View, // camera: every instance; opaque/mask meshes batched, blended meshes back to front
	Shadow, // shadow casters only, no blended meshes
	Shadow_Directional, // as Shadow, but casters in front of the near plane are kept (depth-clamped)
}

// A visible mesh of one instance. instance is the slot index in the instances pool, which is also
// the transform index the vertex shader reads.
DrawItem :: struct {
	mesh:     ^Mesh,
	instance: u32,
}

// One instanced draw: mesh drawn once per id in ids.
DrawRun :: struct {
	mesh: ^Mesh,
	ids:  []u32,
}

DrawList :: struct {
	opaque:            []DrawRun, // one run per mesh, any order
	blended:           []DrawItem, // back to front; drawn one by one, in this order
	instances_visible: u32, // instances whose bounding volume passed the frustum test
	meshes_culled:     u32, // meshes of visible instances whose AABB failed the frustum test
}

// Culls the scene against frustum and returns what a pass of the given kind draws. Allocates with
// the temp allocator and touches nothing outside its arguments: no GPU, no stats.
//
// Rules, matching what the passes did before:
// - Skip dead pool slots. Shadow kinds skip instances that don't cast shadows.
// - Cull each instance by its model's bounding volume (volume_is_on_frustum), then each mesh by its
//   AABB (aabb_is_on_frustum). Shadow_Directional passes skip_near = true to both.
// - Opaque and mask meshes go to opaque, grouped with draw_runs_from_items.
// - Shadow kinds drop blended meshes. View collects each visible instance that has any blended mesh,
//   sorts those instances back to front by distance from camera_pos to the instance's translation,
//   then appends each instance's blended meshes that pass the AABB test, in the model's mesh order.
// - Count instances_visible and meshes_culled (opaque and blended AABB misses both count).
build_draw_list :: proc(view: SceneView, frustum: Frustum, kind: DrawListKind, camera_pos: Vec3) -> DrawList {
	skip_near := kind == .Shadow_Directional

	opaque_items := make([dynamic]DrawItem, context.temp_allocator)
	blended_items := make([dynamic]DrawItem, context.temp_allocator)
	instances_viewed, culled: u32

	BlendedInstance :: struct {
		slot:  u32,
		dist2: f32,
	}
	blended_instances := make([dynamic]BlendedInstance, context.temp_allocator)

	for instance, slot_i in view.instances.values {
		if !pool_is_alive(view.instances, Index(slot_i)) do continue
		if kind != .View && !instance.casts_shadow do continue

		model := pool_get(view.models, instance.model)

		if !volume_is_on_frustum(frustum, model.bounds, instance.transform, skip_near) do continue

		has_blended := false

		for &mesh in model.meshes {
			material := pool_get(view.materials, mesh.material)

			if material.alpha_mode == .Blend {
				has_blended = true
				continue
			}
			if !aabb_is_on_frustum(frustum, mesh.bounds, instance.transform, skip_near) {
				culled += 1
				continue
			}
			append(&opaque_items, DrawItem{mesh = &mesh, instance = u32(slot_i)})
		}

		if kind == .View && has_blended {
			dist2 := linalg.length2(instance.transform.translation - camera_pos)
			append(&blended_instances, BlendedInstance{slot = u32(slot_i), dist2 = dist2})
		}

		instances_viewed += 1
	}

	slice.sort_by(blended_instances[:], proc(a, b: BlendedInstance) -> bool {return a.dist2 > b.dist2})

	for blended_instance in blended_instances {
		instance := view.instances.values[blended_instance.slot]
		model := pool_get(view.models, instance.model)
		for &mesh in model.meshes {
			material := pool_get(view.materials, mesh.material)

			if material.alpha_mode != .Blend do continue
			if !aabb_is_on_frustum(frustum, mesh.bounds, instance.transform, skip_near) {
				culled += 1
				continue
			}
			append(&blended_items, DrawItem{mesh = &mesh, instance = blended_instance.slot})
		}
	}

	return {
		opaque = draw_runs_from_items(opaque_items[:]),
		blended = blended_items[:],
		instances_visible = instances_viewed,
		meshes_culled = culled,
	}
}

// Sorts items by mesh (reordering them) and returns one run per mesh, temp-allocated.
draw_runs_from_items :: proc(items: []DrawItem) -> []DrawRun {
	slice.sort_by(items, proc(a, b: DrawItem) -> bool {return uintptr(a.mesh) < uintptr(b.mesh)})

	runs := make([dynamic]DrawRun, context.temp_allocator)
	ids := make([]u32, len(items), context.temp_allocator)
	for item, i in items do ids[i] = item.instance

	start := 0
	for i in 1 ..= len(items) {
		if i < len(items) && items[i].mesh == items[start].mesh do continue
		append(&runs, DrawRun{mesh = items[start].mesh, ids = ids[start:i]})
		start = i
	}
	return runs[:]
}

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
	View, // camera: every instance; opaque/mask meshes batched, transparent meshes back to front
	Shadow, // shadow casters only, no transparent meshes
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
	transparent:       []DrawItem, // back to front; drawn one by one, in this order
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
// - Shadow kinds drop transparent meshes. View sorts its visible transparent meshes back to front across all
//   instances, by distance from camera_pos to each mesh's world-space AABB center.
// - Count instances_visible and meshes_culled (opaque and transparent AABB misses both count).
build_draw_list :: proc(view: SceneView, frustum: Frustum, kind: DrawListKind, camera_pos: Vec3) -> DrawList {
	skip_near := kind == .Shadow_Directional

	opaque_items := make([dynamic]DrawItem, context.temp_allocator)
	transparent_items := make([dynamic]DrawItem, context.temp_allocator)
	instances_viewed, culled: u32

	TransparentMesh :: struct {
		item:  DrawItem,
		dist2: f32,
	}
	transparent_meshes := make([dynamic]TransparentMesh, context.temp_allocator)

	for instance, slot_i in view.instances.values {
		if !pool_is_alive(view.instances, Index(slot_i)) do continue
		if kind != .View && !instance.casts_shadow do continue

		model := pool_get(view.models, instance.model)

		if !volume_is_on_frustum(frustum, model.bounds, instance.transform, skip_near) do continue

		for &mesh in model.meshes {
			material := pool_get(view.materials, mesh.material)

			transparent := material.alpha_mode == .Blend
			if transparent && kind != .View do continue
			if !aabb_is_on_frustum(frustum, mesh.bounds, instance.transform, skip_near) {
				culled += 1
				continue
			}
			item := DrawItem {
				mesh     = &mesh,
				instance = u32(slot_i),
			}
			if transparent {
				dist2 := linalg.length2(transform_point(instance.transform, mesh.bounds.center) - camera_pos)
				append(&transparent_meshes, TransparentMesh{item = item, dist2 = dist2})
			} else {
				append(&opaque_items, item)
			}
		}

		instances_viewed += 1
	}

	// Back to front by each mesh's world-space AABB center, across instances.
	slice.sort_by(transparent_meshes[:], proc(a, b: TransparentMesh) -> bool {return a.dist2 > b.dist2})
	for transparent in transparent_meshes do append(&transparent_items, transparent.item)

	return {
		opaque = draw_runs_from_items(opaque_items[:]),
		transparent = transparent_items[:],
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

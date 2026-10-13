package graphics

import "core:math/linalg"
import "core:slice"

// What a draw list is built from: the input side of the engine, read-only.
DrawInput :: struct {
	draws:     []DrawRecord, // indexed by draw id
	models:    ^Pool(Model),
	materials: ^Pool(Material),
}

// A visible mesh of one draw. id is the draw id, which is also the transform index the vertex
// shader reads.
DrawItem :: struct {
	mesh: ^Mesh,
	id:   u32,
}

// One instanced draw: mesh drawn once per id in ids.
DrawRun :: struct {
	mesh: ^Mesh,
	ids:  []u32,
}

DrawList :: struct {
	opaque:        []DrawRun, // one run per mesh, any order
	transparent:   []DrawItem, // back to front; drawn one by one, in this order
	draws_visible: u32, // draws whose bounding volume passed the frustum test
	meshes_culled: u32, // meshes of visible draws whose AABB failed the frustum test
}

// Culls the input against the camera's frustum and returns what the main pass draws. Allocates with
// the temp allocator and touches nothing outside its arguments: no GPU, no stats. Shadow views
// filter the shadow caster list instead (shadow_casters.odin).
//
// Rules, matching what the passes did before:
// - Skip free ids.
// - Cull each draw by its model's bounding volume (volume_is_on_frustum), then each mesh by its
//   AABB (aabb_is_on_frustum).
// - Opaque and mask meshes go to opaque, grouped with draw_runs_from_items.
// - Visible transparent meshes are sorted back to front across all draws, by distance from
//   camera_pos to each mesh's world-space AABB center.
// - Count draws_visible and meshes_culled (opaque and transparent AABB misses both count).
build_draw_list :: proc(view: DrawInput, frustum: Frustum, camera_pos: Vec3, gpu_candidates := false) -> DrawList {
	opaque_items := make([dynamic]DrawItem, context.temp_allocator)
	transparent_items := make([dynamic]DrawItem, context.temp_allocator)
	draws_viewed, culled: u32

	TransparentMesh :: struct {
		item:  DrawItem,
		dist2: f32,
	}
	transparent_meshes := make([dynamic]TransparentMesh, context.temp_allocator)

	for record, id in view.draws {
		if record.model == INVALID_MODEL do continue

		model := pool_get(view.models, record.model)

		if !gpu_candidates && !volume_is_on_frustum(frustum, model.bounds, record.world) do continue

		for &mesh in model.meshes {
			material := pool_get(view.materials, mesh.material)

			transparent := material.alpha_mode == .Blend
			if material.alpha_mode != .Blend && gpu_candidates {
				append(&opaque_items, DrawItem{mesh = &mesh, id = u32(id)})
				continue
			}
			if !aabb_is_on_frustum(frustum, mesh.bounds, record.world) {
				culled += 1
				continue
			}
			item := DrawItem {
				mesh = &mesh,
				id   = u32(id),
			}
			if transparent {
				center := record.world * Vec4{mesh.bounds.center.x, mesh.bounds.center.y, mesh.bounds.center.z, 1}
				dist2 := linalg.length2(center.xyz - camera_pos)
				append(&transparent_meshes, TransparentMesh{item = item, dist2 = dist2})
			} else {
				append(&opaque_items, item)
			}
		}

		draws_viewed += 1
	}

	// Back to front by each mesh's world-space AABB center, across draws.
	slice.sort_by(transparent_meshes[:], proc(a, b: TransparentMesh) -> bool {return a.dist2 > b.dist2})
	for transparent in transparent_meshes do append(&transparent_items, transparent.item)

	return {
		opaque = draw_runs_from_items(opaque_items[:]),
		transparent = transparent_items[:],
		draws_visible = draws_viewed,
		meshes_culled = culled,
	}
}

// Groups by mesh range rather than mesh pointer so the order doesn't follow heap addresses, then by
// registration key (material variants share ranges), then draw id.
draw_item_less :: proc(a, b: DrawItem) -> bool {
	ka, kb := a.mesh.first_index, b.mesh.first_index
	if ka != kb do return ka < kb
	if a.mesh.sort_key != b.mesh.sort_key do return a.mesh.sort_key < b.mesh.sort_key
	return a.id < b.id
}

// Sorts items by mesh (reordering them) and returns one run per mesh, temp-allocated.
draw_runs_from_items :: proc(items: []DrawItem) -> []DrawRun {
	slice.sort_by(items, draw_item_less)

	runs := make([dynamic]DrawRun, context.temp_allocator)
	ids := make([]u32, len(items), context.temp_allocator)
	for item, i in items do ids[i] = item.id

	start := 0
	for i in 1 ..= len(items) {
		if i < len(items) && items[i].mesh == items[start].mesh do continue
		append(&runs, DrawRun{mesh = items[start].mesh, ids = ids[start:i]})
		start = i
	}
	return runs[:]
}

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
// shader reads. kind is the main-pass pipeline of an opaque mesh. Only opaque items set it: shadow
// casters and transparent items leave it zero (.Shadow), as neither draws through draw_meshes_opaque.
DrawItem :: struct {
	mesh: ^Mesh,
	id:   u32,
	kind: PipelineKind,
}

// One instanced draw: mesh drawn once per id in ids, with the pipeline kind the run uses.
DrawRun :: struct {
	mesh: ^Mesh,
	kind: PipelineKind,
	ids:  []u32,
}

DrawList :: struct {
	opaque:        []DrawRun, // one run per mesh: by pipeline kind, then nearest run first within a kind
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
// - Opaque and mask meshes go to opaque, grouped with draw_runs_front_to_back. Each takes its pipeline
//   kind from its material.
// - Visible transparent meshes are sorted back to front across all draws, by distance from
//   camera_pos to each mesh's world-space AABB center.
// - Count draws_visible and meshes_culled (opaque and transparent AABB misses both count).
build_draw_list :: proc(view: DrawInput, frustum: Frustum, camera_pos: Vec3) -> DrawList {
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

		if !volume_is_on_frustum(frustum, model.bounds, record.world) do continue

		for &mesh in model.meshes {
			material := pool_get(view.materials, mesh.material)

			transparent := material.alpha_mode == .Blend
			if !aabb_is_on_frustum(frustum, mesh.bounds, record.world) {
				culled += 1
				continue
			}
			item := DrawItem {
				mesh = &mesh,
				id   = u32(id),
			}
			if transparent {
				dist2 := mesh_camera_dist2(record.world, mesh.bounds, camera_pos)
				append(&transparent_meshes, TransparentMesh{item = item, dist2 = dist2})
			} else {
				item.kind = opaque_pipeline_kind(material)
				append(&opaque_items, item)
			}
		}

		draws_viewed += 1
	}

	// Back to front by each mesh's world-space AABB center, across draws.
	slice.sort_by(transparent_meshes[:], proc(a, b: TransparentMesh) -> bool {return a.dist2 > b.dist2})
	for transparent in transparent_meshes do append(&transparent_items, transparent.item)

	return {
		opaque = draw_runs_front_to_back(opaque_items[:], view.draws, camera_pos),
		transparent = transparent_items[:],
		draws_visible = draws_viewed,
		meshes_culled = culled,
	}
}

// The main-pass pipeline an opaque or mask mesh draws with. Enum order puts every opaque kind
// before the masked ones (see PipelineKind).
opaque_pipeline_kind :: proc(material: ^Material) -> PipelineKind {
	masked := material.alpha_mode == .Mask
	switch {
	case masked && material.double_sided:
		return .Mesh_Masked_Double_Sided
	case masked:
		return .Mesh_Masked
	case material.double_sided:
		return .Mesh_Double_Sided
	}
	return .Mesh
}

// Groups by pipeline kind first, so runs of one kind are drawn together. Then by mesh, keyed by
// vertex buffer slot rather than mesh pointer so the order doesn't follow heap addresses, then by
// registration key (material variants share buffers), then draw id.
draw_item_less :: proc(a, b: DrawItem) -> bool {
	if a.kind != b.kind do return a.kind < b.kind
	ka, kb := a.mesh.vertex_buffer.handle.index, b.mesh.vertex_buffer.handle.index
	if ka != kb do return ka < kb
	if a.mesh.sort_key != b.mesh.sort_key do return a.mesh.sort_key < b.mesh.sort_key
	return a.id < b.id
}

// Squared distance from the camera to the world-space AABB center of one mesh of a draw.
mesh_camera_dist2 :: proc(world: Mat4x4, bounds: AABB, camera_pos: Vec3) -> f32 {
	center := world * Vec4{bounds.center.x, bounds.center.y, bounds.center.z, 1}
	return linalg.length2(center.xyz - camera_pos)
}

// Returns one run per mesh, temp-allocated. The items are sorted by draw_item_less first, so each run's
// ids stay in draw id order and the items of one mesh are contiguous. Runs are grouped by pipeline kind,
// opaque kinds first. Within a kind they go front to back by the nearest instance of each mesh: the
// minimum squared distance from the camera to the instance's AABB center. sort_key breaks ties.
// Center distance, not the closest point of the box: a box that contains the camera has distance 0,
// so large enclosing meshes would draw first and defeat early-z.
draw_runs_front_to_back :: proc(items: []DrawItem, draws: []DrawRecord, camera_pos: Vec3) -> []DrawRun {
	slice.sort_by(items, draw_item_less)

	ids := make([]u32, len(items), context.temp_allocator)
	for item, i in items do ids[i] = item.id

	Span :: struct {
		start, end: int,
		mesh:       ^Mesh,
		kind:       PipelineKind,
		nearest:    f32,
	}
	spans := make([dynamic]Span, context.temp_allocator)
	start := 0
	for i in 1 ..= len(items) {
		if i < len(items) && items[i].mesh == items[start].mesh do continue
		nearest := max(f32)
		for item in items[start:i] {
			nearest = min(nearest, mesh_camera_dist2(draws[item.id].world, item.mesh.bounds, camera_pos))
		}
		first := items[start]
		append(&spans, Span{start = start, end = i, mesh = first.mesh, kind = first.kind, nearest = nearest})
		start = i
	}

	slice.sort_by(spans[:], proc(a, b: Span) -> bool {
		if a.kind != b.kind do return a.kind < b.kind
		if a.nearest != b.nearest do return a.nearest < b.nearest
		return a.mesh.sort_key < b.mesh.sort_key
	})

	runs := make([]DrawRun, len(spans), context.temp_allocator)
	for span, i in spans {
		runs[i] = DrawRun {
			mesh = span.mesh,
			kind = span.kind,
			ids  = ids[span.start:span.end],
		}
	}
	return runs
}

package graphics

import "core:math/linalg"

ShadowAtlasKind :: enum {
	Atlas_2D, // directional cascades, then spot maps from SPOT_SHADOW_SLOT_BASE
	Cube, // 6 faces per point light
}

// One depth pass into atlas layers [layer, layer + view_count): a single layer, or every cascade of a
// directional light as one multiview pass (a view per cascade).
ShadowView :: struct {
	atlas:       ShadowAtlasKind,
	layer:       u32,
	view_count:  u32,
	light_type:  LightType,
	light_index: u32,
	view_proj:   [SHADOW_MAP_CASCADE_COUNT]Mat4x4, // per view; the first view_count are set
}

// What the shadow passes render this frame. Built by shadow_plan, read by the input data upload and
// the shadow passes, applied to the cache by shadow_cache_commit.
ShadowPlan :: struct {
	// Every light in the input's counts, masked or not; the input data copies these.
	shadow_2d_view_proj: [MAX_SHADOW_2D_SLOTS]Mat4x4,
	point_view_proj:     [MAX_POINT_SHADOW_LIGHTS][6]Mat4x4,
	cascade_data:        [MAX_DIRECTIONAL_LIGHTS]GpuShadowCascadeData,
	views:               [dynamic]ShadowView, // 2D atlas views first, then cube faces
	views_cached:        u32, // spot maps + cube faces skipped because the cache holds them
	invalidated_point:   [MAX_POINT_SHADOW_LIGHTS]bool,
	invalidated_spot:    [MAX_SPOT_LIGHTS]bool,
	// Set by shadow_passes_build: lights with a view that lost casters to the frame budget.
	dropped_point:       [MAX_POINT_SHADOW_LIGHTS]bool,
	dropped_spot:        [MAX_SPOT_LIGHTS]bool,
}

// Decides this frame's shadow work. Reads its inputs only; views is allocated with allocator.
//
// shadow_lights is the light types that render shadows (empty when shadows are off).
//
// Rules:
// - Matrices for every light within the input's counts, masked or not: cascades from
//   compute_directional_shadow_data (slots light * SHADOW_MAP_CASCADE_COUNT + cascade, split/bias
//   into cascade_data), spot from compute_spot_light_view_proj (slot SPOT_SHADOW_SLOT_BASE + light),
//   point from compute_point_light_view_proj.
// - Directional: one view per light, covering its SHADOW_MAP_CASCADE_COUNT cascade slots (contiguous
//   layers from light * SHADOW_MAP_CASCADE_COUNT), unless Directional is masked.
// - Spot and point: invalidated when the cached key differs from the light's key, or a caster's
//   draw change overlaps the light's bound (a sphere of radius range around the light, also for
//   spots). Invalidation is recorded whether the light is masked or not.
// - A light not masked renders when it is invalidated or its cache entry isn't valid; otherwise it
//   counts in views_cached (1 per spot, 6 per point light).
// - View order: directional lights, spots, then point faces (light * 6 + face).
shadow_plan :: proc(
	lights: ^LightData,
	changes: []DrawChange,
	camera: Camera,
	aspect: f32,
	cache: ^ShadowCache,
	shadow_lights: LightTypes,
	allocator := context.temp_allocator,
) -> (
	plan: ShadowPlan,
) {
	plan.views = make([dynamic]ShadowView, allocator)
	dir_count := min(int(lights.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	spot_count := min(int(lights.spot_light_count), MAX_SPOT_LIGHTS)
	point_count := min(int(lights.point_light_count), MAX_POINT_SHADOW_LIGHTS)
	for l in 0 ..< dir_count {
		data := compute_directional_shadow_data(lights.directional_lights[l], camera, {aspect = aspect})
		for c in 0 ..< SHADOW_MAP_CASCADE_COUNT do plan.shadow_2d_view_proj[l * SHADOW_MAP_CASCADE_COUNT + c] = data.view_proj[c]
		plan.cascade_data[l] = {
			split = data.splits,
			bias  = data.bias,
		}
		if .Directional not_in shadow_lights do continue
		append(
			&plan.views,
			ShadowView {
				atlas = .Atlas_2D,
				layer = u32(l * SHADOW_MAP_CASCADE_COUNT),
				view_count = SHADOW_MAP_CASCADE_COUNT,
				light_type = .Directional,
				light_index = u32(l),
				view_proj = data.view_proj,
			},
		)
	}
	for l in 0 ..< spot_count {
		slot := SPOT_SHADOW_SLOT_BASE + u32(l)
		plan.shadow_2d_view_proj[slot] = compute_spot_light_view_proj(lights.spot_lights[l])
		light := lights.spot_lights[l]
		plan.invalidated_spot[l] = shadow_entry_invalidated(
			cache.spot[l],
			spot_shadow_key(light),
			light.pos,
			light.range,
			changes,
		)
		if .Spot not_in shadow_lights do continue
		if cache.spot[l].valid && !plan.invalidated_spot[l] {
			plan.views_cached += 1
			continue
		}
		append(&plan.views, single_view(.Atlas_2D, slot, .Spot, u32(l), plan.shadow_2d_view_proj[slot]))
	}
	for l in 0 ..< point_count {
		plan.point_view_proj[l] = compute_point_light_view_proj(lights.point_lights[l])
		light := lights.point_lights[l]
		plan.invalidated_point[l] = shadow_entry_invalidated(
			cache.point[l],
			point_shadow_key(light),
			light.pos,
			light.range,
			changes,
		)
		if .Point not_in shadow_lights do continue
		if cache.point[l].valid && !plan.invalidated_point[l] {
			plan.views_cached += 6
			continue
		}
		for f in 0 ..< 6 do append(&plan.views, single_view(.Cube, u32(l * 6 + f), .Point, u32(l), plan.point_view_proj[l][f]))
	}
	return
}

@(private = "file")
single_view :: proc(
	atlas: ShadowAtlasKind,
	layer: u32,
	light_type: LightType,
	light_index: u32,
	view_proj: Mat4x4,
) -> ShadowView {
	return {
		atlas = atlas,
		layer = layer,
		view_count = 1,
		light_type = light_type,
		light_index = light_index,
		view_proj = {0 = view_proj},
	}
}

// Same rule for point and spot entries: the light's key changed, or a caster entered, left or moved
// inside the sphere of radius range around the light.
@(private = "file")
shadow_entry_invalidated :: proc(
	entry: ShadowCacheEntry($Key),
	key: Key,
	light_pos: Vec3,
	light_range: f32,
	changes: []DrawChange,
) -> bool {
	if entry.key != key do return true
	bound := BoundingSphere{light_pos, light_range}
	for change in changes {
		if change.kind != .Despawn && change.new.casts_shadow && spheres_overlap(change.new.bounds, bound) do return true
		if change.kind != .Spawn && change.old.casts_shadow && spheres_overlap(change.old.bounds, bound) do return true
	}
	return false
}

@(private = "file")
spheres_overlap :: proc(a, b: BoundingSphere) -> bool {
	r := a.radius + b.radius
	return linalg.length2(a.center - b.center) <= r * r
}

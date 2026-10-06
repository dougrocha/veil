package graphics

import "core:math/linalg"

ShadowAtlasKind :: enum {
	Atlas_2D, // directional cascades, then spot maps from SPOT_SHADOW_SLOT_BASE
	Cube, // 6 faces per point light
}

// One depth render into one atlas layer.
ShadowView :: struct {
	atlas:       ShadowAtlasKind,
	layer:       u32,
	light_type:  ShadowLightType,
	light_index: u32,
	view_proj:   Mat4x4,
}

// What the shadow passes render this frame. Built by shadow_plan, read by the scene data upload and
// the shadow passes, applied to the cache by shadow_cache_commit.
ShadowPlan :: struct {
	// Every light in the scene's counts, masked or not; the scene data copies these.
	shadow_2d_view_proj: [MAX_SHADOW_2D_SLOTS]Mat4x4,
	point_view_proj:     [MAX_POINT_LIGHTS][6]Mat4x4,
	cascade_data:        [MAX_DIRECTIONAL_LIGHTS]ShadowCascadeData,
	views:               [dynamic]ShadowView, // 2D atlas views first, then cube faces
	views_cached:        u32, // spot maps + cube faces skipped because the cache holds them
	invalidated_point:   [MAX_POINT_LIGHTS]bool,
	invalidated_spot:    [MAX_SPOT_LIGHTS]bool,
}

// Decides this frame's shadow work. Reads its inputs only; views is allocated with allocator.
//
// light_mask is the LightMask bits of the light types that render shadows (0 when shadows are off).
//
// Rules:
// - Matrices for every light within the scene's counts, masked or not: cascades from
//   compute_directional_shadow_data (slots light * SHADOW_MAP_CASCADE_COUNT + cascade, split/bias
//   into cascade_data), spot from compute_spot_light_view_proj (slot SPOT_SHADOW_SLOT_BASE + light),
//   point from compute_point_light_view_proj.
// - Directional: every cascade of every light is a view unless Directional is masked.
// - Spot and point: invalidated when the cached key differs from the light's key, or a caster's
//   instance change overlaps the light's bound (a sphere of radius range around the light, also for
//   spots). Invalidation is recorded whether the light is masked or not.
// - A light not masked renders when it is invalidated or its cache entry isn't valid; otherwise it
//   counts in views_cached (1 per spot, 6 per point light).
// - View order: cascades, spots, then point faces (light * 6 + face).
shadow_plan :: proc(
	scene: ^Scene,
	camera: Camera,
	aspect: f32,
	cache: ^ShadowCache,
	light_mask: u32,
	allocator := context.temp_allocator,
) -> (
	plan: ShadowPlan,
) {
	plan.views = make([dynamic]ShadowView, allocator)
	dir_count := min(int(scene.directional_light_count), MAX_DIRECTIONAL_LIGHTS)
	spot_count := min(int(scene.spot_light_count), MAX_SPOT_LIGHTS)
	point_count := min(int(scene.point_light_count), MAX_POINT_LIGHTS)
	for l in 0 ..< dir_count {
		data := compute_directional_shadow_data(scene.directional_lights[l], camera, {aspect = aspect})
		for c in 0 ..< SHADOW_MAP_CASCADE_COUNT do plan.shadow_2d_view_proj[l * SHADOW_MAP_CASCADE_COUNT + c] = data.view_proj[c]
		plan.cascade_data[l] = {
			split = data.splits,
			bias  = data.bias,
		}
		if light_mask & u32(LightMask.Directional) == 0 do continue
		for c in 0 ..< SHADOW_MAP_CASCADE_COUNT {
			slot := u32(l * SHADOW_MAP_CASCADE_COUNT + c)
			append(&plan.views, ShadowView{.Atlas_2D, slot, .Directional, u32(l), plan.shadow_2d_view_proj[slot]})
		}
	}
	for l in 0 ..< spot_count {
		slot := SPOT_SHADOW_SLOT_BASE + u32(l)
		plan.shadow_2d_view_proj[slot] = compute_spot_light_view_proj(scene.spot_lights[l])
		light := scene.spot_lights[l]
		plan.invalidated_spot[l] = shadow_entry_invalidated(
			cache.spot[l],
			spot_shadow_key(light),
			light.pos,
			light.range,
			scene.instance_changes[:],
		)
		if light_mask & u32(LightMask.Spot) == 0 do continue
		if cache.spot[l].valid && !plan.invalidated_spot[l] {
			plan.views_cached += 1
			continue
		}
		append(&plan.views, ShadowView{.Atlas_2D, slot, .Spot, u32(l), plan.shadow_2d_view_proj[slot]})
	}
	for l in 0 ..< point_count {
		plan.point_view_proj[l] = compute_point_light_view_proj(scene.point_lights[l])
		light := scene.point_lights[l]
		plan.invalidated_point[l] = shadow_entry_invalidated(
			cache.point[l],
			point_shadow_key(light),
			light.pos,
			light.range,
			scene.instance_changes[:],
		)
		if light_mask & u32(LightMask.Point) == 0 do continue
		if cache.point[l].valid && !plan.invalidated_point[l] {
			plan.views_cached += 6
			continue
		}
		for f in 0 ..< 6 do append(&plan.views, ShadowView{.Cube, u32(l * 6 + f), .Point, u32(l), plan.point_view_proj[l][f]})
	}
	return
}

// Same rule for point and spot entries: the light's key changed, or a caster entered, left or moved
// inside the sphere of radius range around the light.
@(private = "file")
shadow_entry_invalidated :: proc(
	entry: ShadowCacheEntry($Key),
	key: Key,
	light_pos: Vec3,
	light_range: f32,
	changes: []InstanceChange,
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

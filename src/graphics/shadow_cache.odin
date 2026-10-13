package graphics

// Point and spot shadow maps depend only on the light's shadow frustum and the shadow casters, so
// they are re-rendered only when one of those changes. Directional cascades follow the camera and
// render every frame. Lights are compared by key; casters report changes through the draw changes
// draw_history_sync derives from each packet. shadow_cache_commit and shadow_cache_invalidate are
// the only writers.

PointShadowKey :: struct {
	pos:         Vec3,
	range:       f32,
	shadow_near: f32,
}

SpotShadowKey :: struct {
	pos:          Vec3,
	direction:    Vec3,
	range:        f32,
	shadow_near:  f32,
	outer_cutoff: f32,
}

ShadowCacheEntry :: struct($Key: typeid) {
	key:   Key,
	valid: bool,
}

ShadowCache :: struct {
	point: [MAX_POINT_SHADOW_LIGHTS]ShadowCacheEntry(PointShadowKey),
	spot:  [MAX_SPOT_LIGHTS]ShadowCacheEntry(SpotShadowKey),
}

point_shadow_key :: proc(light: PointLight) -> PointShadowKey {
	return {light.pos, light.range, light.shadow_near}
}

spot_shadow_key :: proc(light: SpotLight) -> SpotShadowKey {
	return {light.pos, light.direction, light.range, light.shadow_near, light.outer_cutoff}
}

// Forces every point and spot map to re-render, e.g. after the shadow shader reloads.
shadow_cache_invalidate :: proc(cache: ^ShadowCache) {
	for &entry in cache.point do entry.valid = false
	for &entry in cache.spot do entry.valid = false
}

// Applies a recorded plan: clears the entries it invalidated, then marks the lights it rendered
// valid with their current keys, except lights whose views dropped casters. Runs every frame, even
// when the shadow passes are disabled.
shadow_cache_commit :: proc(cache: ^ShadowCache, plan: ^ShadowPlan, lights: ^LightData) {
	shadow_entries_clear(cache.point[:], plan.invalidated_point[:])
	shadow_entries_clear(cache.spot[:], plan.invalidated_spot[:])
	for view in plan.views {
		switch view.light_type {
		case .Directional:
		case .Point:
			if plan.dropped_point[view.light_index] do continue
			shadow_entry_rendered(
				&cache.point[view.light_index],
				point_shadow_key(lights.point_lights[view.light_index]),
			)
		case .Spot:
			if plan.dropped_spot[view.light_index] do continue
			shadow_entry_rendered(&cache.spot[view.light_index], spot_shadow_key(lights.spot_lights[view.light_index]))
		}
	}
}

@(private = "file")
shadow_entries_clear :: proc(entries: []ShadowCacheEntry($Key), invalidated: []bool) {
	for hit, i in invalidated do if hit do entries[i].valid = false
}

@(private = "file")
shadow_entry_rendered :: proc(entry: ^ShadowCacheEntry($Key), key: Key) {
	entry^ = {key, true}
}

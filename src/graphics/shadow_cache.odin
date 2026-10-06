package graphics

// Point and spot shadow maps depend only on the light's shadow frustum and the shadow casters, so
// they are re-rendered only when one of those changes. Directional cascades follow the camera and
// render every frame. Lights are compared by key; casters report changes through the scene's
// instance changes, which only describe edits within one scene epoch; a new epoch drops every
// entry. shadow_cache_sync_scene, shadow_cache_commit and shadow_cache_invalidate are the only writers.

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
	scene_epoch: u64, // the Scene.epoch the entries were rendered against; 0 before the first frame
	point:       [MAX_POINT_LIGHTS]ShadowCacheEntry(PointShadowKey),
	spot:        [MAX_SPOT_LIGHTS]ShadowCacheEntry(SpotShadowKey),
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

// Drops every entry when the scene's contents were replaced since the last plan, e.g. a different
// scene or a reloaded level: their casters left without recording Despawn changes.
shadow_cache_sync_scene :: proc(cache: ^ShadowCache, scene: ^Scene) {
	if cache.scene_epoch == scene.epoch do return
	shadow_cache_invalidate(cache)
	cache.scene_epoch = scene.epoch
}

// Applies a recorded plan: clears the entries it invalidated, then marks the lights it rendered
// valid with their current keys. Runs every frame, even when the shadow passes are disabled.
shadow_cache_commit :: proc(cache: ^ShadowCache, plan: ^ShadowPlan, scene: ^Scene) {
	shadow_entries_clear(cache.point[:], plan.invalidated_point[:])
	shadow_entries_clear(cache.spot[:], plan.invalidated_spot[:])
	for view in plan.views {
		switch view.light_type {
		case .Directional:
		case .Point:
			shadow_entry_rendered(
				&cache.point[view.light_index],
				point_shadow_key(scene.point_lights[view.light_index]),
			)
		case .Spot:
			shadow_entry_rendered(&cache.spot[view.light_index], spot_shadow_key(scene.spot_lights[view.light_index]))
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

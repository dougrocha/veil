package graphics

// TODO: rewrite. Point/spot procs are near-duplicates, and every instance slot is compared every
// frame. Revisit the design: dirty flags vs compare-to-last-frame, and who owns change detection.

// Point and spot shadow maps depend only on the light's shadow frustum and the shadow casters, so
// they are re-rendered only when one of those changes. Directional cascades follow the camera and
// render every frame. Changes are detected by comparison rather than dirty flags, since game code
// writes lights and instance transforms directly.

// Whatever about an instance ends up in a shadow map.
@(private = "file")
CasterState :: struct {
	generation:   Generation, // changes on spawn, free, and slot reuse
	model:        ModelHandle,
	transform:    Transform,
	casts_shadow: bool,
}

@(private = "file")
PointShadowKey :: struct {
	pos:         Vec3,
	range:       f32,
	shadow_near: f32,
}

@(private = "file")
SpotShadowKey :: struct {
	pos:          Vec3,
	direction:    Vec3,
	range:        f32,
	shadow_near:  f32,
	outer_cutoff: f32,
}

@(private = "file")
CachedView :: struct($Key: typeid) {
	key:             Key,
	casters_version: u64,
	valid:           bool,
}

ShadowCache :: struct {
	casters:         []CasterState,
	casters_version: u64, // bumped whenever any caster changes
	point:           [MAX_POINT_LIGHTS]CachedView(PointShadowKey),
	spot:            [MAX_SPOT_LIGHTS]CachedView(SpotShadowKey),
}

shadow_cache_create :: proc(engine: ^Engine) {
	engine.shadow_cache.casters = make([]CasterState, len(engine.scene.instances.values))
}

shadow_cache_destroy :: proc(engine: ^Engine) {
	delete(engine.shadow_cache.casters)
}

// Forces every point and spot map to re-render, e.g. after the shadow shader reloads.
shadow_cache_invalidate :: proc(engine: ^Engine) {
	engine.shadow_cache.casters_version += 1
}

// Compares every instance slot against last frame. Call once per frame before recording shadows.
shadow_cache_update :: proc(engine: ^Engine) {
	cache := &engine.shadow_cache
	pool := &engine.scene.instances
	changed := false
	for &prev, i in cache.casters {
		instance := &pool.values[i]
		current := CasterState {
			generation = pool.generations[i],
		}
		// Dead slots only differ by generation; their stale payload is irrelevant.
		if pool_is_alive(pool, Index(i)) {
			current.model = instance.model
			current.transform = instance.transform
			current.casts_shadow = instance.casts_shadow
		}
		if current != prev {
			// A slot that never cast a shadow before or after can't change any map.
			if prev.casts_shadow || current.casts_shadow do changed = true
			prev = current
		}
	}
	if changed do cache.casters_version += 1
}

@(private = "file")
view_is_fresh :: proc(view: ^CachedView($Key), key: Key, casters_version: u64) -> bool {
	return view.valid && view.key == key && view.casters_version == casters_version
}

// True when the point light's cube map from a previous frame is still correct.
shadow_cache_point_fresh :: proc(engine: ^Engine, light_index: int) -> bool {
	light := &engine.scene.point_lights[light_index]
	key := PointShadowKey{light.pos, light.range, light.shadow_near}
	cache := &engine.shadow_cache
	return view_is_fresh(&cache.point[light_index], key, cache.casters_version)
}

shadow_cache_point_rendered :: proc(engine: ^Engine, light_index: int) {
	light := &engine.scene.point_lights[light_index]
	cache := &engine.shadow_cache
	cache.point[light_index] = {
		key             = {light.pos, light.range, light.shadow_near},
		casters_version = cache.casters_version,
		valid           = true,
	}
}

shadow_cache_spot_fresh :: proc(engine: ^Engine, light_index: int) -> bool {
	light := &engine.scene.spot_lights[light_index]
	key := SpotShadowKey{light.pos, light.direction, light.range, light.shadow_near, light.outer_cutoff}
	cache := &engine.shadow_cache
	return view_is_fresh(&cache.spot[light_index], key, cache.casters_version)
}

shadow_cache_spot_rendered :: proc(engine: ^Engine, light_index: int) {
	light := &engine.scene.spot_lights[light_index]
	cache := &engine.shadow_cache
	cache.spot[light_index] = {
		key             = {light.pos, light.direction, light.range, light.shadow_near, light.outer_cutoff},
		casters_version = cache.casters_version,
		valid           = true,
	}
}

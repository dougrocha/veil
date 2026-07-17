package graphics

import "core:math"
import "core:math/linalg"

// Casts a ray from the active camera through mouse_pos (screen-space pixels) and
// returns the closest instance it hits, or INVALID_INSTANCE if nothing was hit.
pick :: proc(engine: ^Engine, mouse_pos: Vec2) -> InstanceHandle {
	cam := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	viewport_size := Vec2{f32(engine.swapchain.extent.width), f32(engine.swapchain.extent.height)}

	ray_origin, ray_dir := screen_to_world_ray(cam^, mouse_pos, viewport_size)

	closest_dist: f32 = math.F32_MAX
	closest_instance := INVALID_INSTANCE
	found_hit := false

	for instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(i)) do continue

		model := pool_get(&engine.model_system.models, instance.model)

		global_center :=
			transform_to_matrix(instance.transform) *
			Vec4{model.bounds.center.x, model.bounds.center.y, model.bounds.center.z, 1}
		global_scale := transform_global_scale(instance.transform)
		max_scale := max(global_scale.x, global_scale.y, global_scale.z)

		sphere := BoundingSphere{global_center.xyz, model.bounds.radius * max_scale}

		to_center := sphere.center - ray_origin
		proj_length := linalg.dot(to_center, ray_dir)
		perp_dist_sq := linalg.dot(to_center, to_center) - proj_length * proj_length

		if perp_dist_sq > sphere.radius * sphere.radius {
			continue // ray line never comes within the sphere's radius -> miss
		}

		half_chord := math.sqrt(sphere.radius * sphere.radius - perp_dist_sq)
		t_near := proj_length - half_chord
		t_far := proj_length + half_chord

		hit_t: f32
		if t_near >= 0 {
			hit_t = t_near
		} else if t_far >= 0 {
			hit_t = t_far
		} else {
			continue // both behind -> miss
		}

		if hit_t < closest_dist {
			closest_dist = hit_t
			closest_instance = InstanceHandle {
				index      = Index(i),
				generation = engine.scene.instances.generations[i],
			}
			found_hit = true
		}
	}

	if !found_hit {
		return INVALID_INSTANCE
	}
	return closest_instance
}

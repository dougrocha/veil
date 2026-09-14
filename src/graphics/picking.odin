package graphics

import "core:math"
import "core:math/linalg"

// Returns the distance along a ray to a triangle, including back faces.
ray_triangle_hit :: proc(origin, dir, a, b, c: Vec3) -> (f32, bool) {
	edge1 := b - a
	edge2 := c - a
	p := linalg.cross(dir, edge2)
	det := linalg.dot(edge1, p)
	if math.abs(det) < 1e-7 do return 0, false

	inv_det := 1 / det
	from_a := origin - a
	u := linalg.dot(from_a, p) * inv_det
	if u < 0 || u > 1 do return 0, false

	q := linalg.cross(from_a, edge1)
	v := linalg.dot(dir, q) * inv_det
	if v < 0 || u + v > 1 do return 0, false

	t := linalg.dot(edge2, q) * inv_det
	return t, t > 1e-6
}

// Casts a ray from the active camera through mouse_pos (screen-space pixels) and
// returns the closest instance whose triangles it hits.
pick :: proc(engine: ^Engine, mouse_pos: Vec2) -> InstanceHandle {
	cam := camera_system_get_camera(&engine.camera_system, engine.scene.active_camera_name)
	viewport_size := Vec2{f32(engine.swapchain.extent.width), f32(engine.swapchain.extent.height)}

	ray_origin, ray_dir := screen_to_world_ray(cam^, mouse_pos, viewport_size)

	closest_dist: f32 = math.F32_MAX
	closest_instance := INVALID_INSTANCE

	for instance, i in engine.scene.instances.values {
		if !pool_is_alive(&engine.scene.instances, Index(i)) do continue

		model := pool_get(&engine.model_system.models, instance.model)

		global_center :=
			transform_to_matrix(instance.transform) *
			Vec4{model.bounds.center.x, model.bounds.center.y, model.bounds.center.z, 1}
		global_scale := transform_global_scale(instance.transform)
		max_scale := max(math.abs(global_scale.x), math.abs(global_scale.y), math.abs(global_scale.z))

		sphere := BoundingSphere{global_center.xyz, model.bounds.radius * max_scale}

		to_center := sphere.center - ray_origin
		proj_length := linalg.dot(to_center, ray_dir)
		perp_dist_sq := linalg.dot(to_center, to_center) - proj_length * proj_length

		if perp_dist_sq > sphere.radius * sphere.radius {
			continue // ray line never comes within the sphere's radius -> miss
		}

		if proj_length + math.sqrt(sphere.radius * sphere.radius - perp_dist_sq) < 0 do continue

		// Keep the transformed direction unnormalized: local triangle t then
		// measures the same world-space ray distance for every instance.
		if instance.transform.scale.x == 0 || instance.transform.scale.y == 0 || instance.transform.scale.z == 0 do continue
		inverse_model := linalg.inverse(transform_to_matrix(instance.transform))
		local_origin := (inverse_model * Vec4{ray_origin.x, ray_origin.y, ray_origin.z, 1}).xyz
		local_dir := (inverse_model * Vec4{ray_dir.x, ray_dir.y, ray_dir.z, 0}).xyz

		for &mesh in model.meshes {
			for triangle := 0; triangle + 2 < len(mesh.indices); triangle += 3 {
				a := mesh.positions[mesh.indices[triangle]]
				b := mesh.positions[mesh.indices[triangle + 1]]
				c := mesh.positions[mesh.indices[triangle + 2]]
				hit_t, hit := ray_triangle_hit(local_origin, local_dir, a, b, c)
				if hit && hit_t < closest_dist {
					closest_dist = hit_t
					closest_instance = InstanceHandle {
						index      = Index(i),
						generation = engine.scene.instances.generations[i],
					}
				}
			}
		}
	}

	return closest_instance
}

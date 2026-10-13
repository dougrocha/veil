package graphics

import "backend"
import "core:log"
import "core:math"
import "core:math/linalg"

@(shader_shared)
CLUSTER_X :: 16
@(shader_shared)
CLUSTER_Y :: 9
@(shader_shared)
CLUSTER_Z :: 24
@(shader_shared)
CLUSTER_COUNT :: CLUSTER_X * CLUSTER_Y * CLUSTER_Z
// Cap global storage at 128K indices (512 KiB per frame slot); overflow is clamped and reported.
@(shader_shared)
CLUSTER_INDEX_CAPACITY :: 131072
@(shader_shared)
CLUSTER_OVERFLOW_BIT :: 0x80000000

@(shader_shared)
ClusterHeader :: struct #max_field_align(16) {
	light_offset: u32,
	light_count:  u32,
}

@(private = "file")
cluster_has :: proc(headers: []ClusterHeader, indices: []u32, cluster: int, item: u32) -> bool {
	h := headers[cluster]
	if (h.light_count & CLUSTER_OVERFLOW_BIT) != 0 do return false
	for value in indices[int(h.light_offset):][:int(h.light_count)] {
		if value == item do return true
	}
	return false
}

@(shader_shared)
ClusterPushConstants :: struct #max_field_align(16) {
	scene_data: backend.GPUPtr(SceneData),
	clusters:   backend.GPUPtr(ClusterHeader),
	indices:    backend.GPUPtr(u32),
	counter:    backend.GPUPtr(u32),
}

ClusterBuffers :: struct {
	headers:          backend.Buffer(ClusterHeader),
	indices:          backend.Buffer(u32),
	counter:          backend.Buffer(u32),
	readback_headers: backend.Buffer(ClusterHeader),
	readback_indices: backend.Buffer(u32),
	readback_counter: backend.Buffer(u32),
	debug_counter:    backend.Buffer(u32),
}

cluster_buffers_create :: proc(engine: ^Engine) {
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		engine.frame_data[i].clusters.headers = backend.buffer_create(
			ClusterHeader,
			&engine.vk_ctx,
			CLUSTER_COUNT,
			{.Storage, .Transfer_Src},
			.Gpu,
		)
		engine.frame_data[i].clusters.indices = backend.buffer_create(
			u32,
			&engine.vk_ctx,
			CLUSTER_INDEX_CAPACITY,
			{.Storage, .Transfer_Dst, .Transfer_Src},
			.Gpu,
		)
		engine.frame_data[i].clusters.counter = backend.buffer_create(
			u32,
			&engine.vk_ctx,
			1,
			{.Storage, .Transfer_Dst, .Transfer_Src},
			.Gpu,
		)
		when ODIN_DEBUG {
			engine.frame_data[i].clusters.debug_counter = backend.buffer_create(
				u32,
				&engine.vk_ctx,
				1,
				{.Transfer_Dst},
				.Readback,
			)
		}
		if engine.cluster_validate {
			engine.frame_data[i].clusters.readback_headers = backend.buffer_create(
				ClusterHeader,
				&engine.vk_ctx,
				CLUSTER_COUNT,
				{.Transfer_Dst},
				.Readback,
			)
			engine.frame_data[i].clusters.readback_indices = backend.buffer_create(
				u32,
				&engine.vk_ctx,
				CLUSTER_INDEX_CAPACITY,
				{.Transfer_Dst},
				.Readback,
			)
			engine.frame_data[i].clusters.readback_counter = backend.buffer_create(
				u32,
				&engine.vk_ctx,
				1,
				{.Transfer_Dst},
				.Readback,
			)
		}
	}
}

cluster_buffers_destroy :: proc(engine: ^Engine) {
	for &frame in engine.frame_data {
		backend.buffer_destroy(&engine.vk_ctx, frame.clusters.headers)
		backend.buffer_destroy(&engine.vk_ctx, frame.clusters.indices)
		backend.buffer_destroy(&engine.vk_ctx, frame.clusters.counter)
		when ODIN_DEBUG {
			backend.buffer_destroy(&engine.vk_ctx, frame.clusters.debug_counter)
		}
		if backend.buffer_is_valid(&engine.vk_ctx, frame.clusters.readback_headers) {
			backend.buffer_destroy(&engine.vk_ctx, frame.clusters.readback_headers)
			backend.buffer_destroy(&engine.vk_ctx, frame.clusters.readback_indices)
			backend.buffer_destroy(&engine.vk_ctx, frame.clusters.readback_counter)
		}
	}
}

cluster_debug_report_overflow :: proc(engine: ^Engine, slot: int) {
	when ODIN_DEBUG {
		if engine.frame_count % 120 != 0 do return
		frame := &engine.frame_data[slot]
		backend.buffer_copy_compute_readback(&engine.vk_ctx, frame.clusters.counter, frame.clusters.debug_counter, 1)
		count := make([]u32, 1, context.temp_allocator)
		backend.buffer_read(&engine.vk_ctx, frame.clusters.debug_counter, count)
		if count[0] > CLUSTER_INDEX_CAPACITY {
			log.warnf("cluster index overflow: requested %d indices, capacity %d", count[0], CLUSTER_INDEX_CAPACITY)
		}
	}
}

// Dispatch size for the cluster build, one invocation per cluster.
ClustersPrep :: struct {
	groups: u32,
}

// Runs when clustered lighting, the heatmap, or validation needs it.
clusters_prepare :: proc(camera: Camera, enabled: bool) -> Maybe(ClustersPrep) {
	if !enabled do return nil
	assert(camera.near > 0, "cluster depth slices require a positive near plane")
	return ClustersPrep{groups = (CLUSTER_COUNT + 63) / 64}
}

record_clusters :: proc(r: ^Recorder, f: ^PreparedFrame) {
	frame := r.frame
	pc := ClusterPushConstants {
		scene_data = backend.buffer_address(r.ctx, frame.scene_data_buffer),
		clusters   = backend.buffer_address(r.ctx, frame.clusters.headers),
		indices    = backend.buffer_address(r.ctx, frame.clusters.indices),
		counter    = backend.buffer_address(r.ctx, frame.clusters.counter),
	}
	backend.cmd_fill_u32(r.cmd, frame.clusters.counter, 0)
	encoder := backend.begin_compute_pass(r.cmd)
	backend.pipeline_bind_compute(encoder, rec_pipeline(r, .Clusters))
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, f.passes.clusters.?.groups, 1, 1)
	backend.cmd_barrier_compute_write_to_fragment_read(encoder)
	backend.end_compute_pass(encoder)
}

// Validation reads back only the completed slot passed by engine_render.
cluster_debug_validate :: proc(engine: ^Engine, slot: int) {
	if !engine.cluster_validate do return
	engine.cluster_validate = false
	frame := &engine.frame_data[slot]
	headers := make([]ClusterHeader, CLUSTER_COUNT, context.temp_allocator)
	indices := make([]u32, CLUSTER_INDEX_CAPACITY, context.temp_allocator)
	count_out := make([]u32, 1, context.temp_allocator)
	backend.buffer_copy_compute_readback(
		&engine.vk_ctx,
		frame.clusters.headers,
		frame.clusters.readback_headers,
		CLUSTER_COUNT,
	)
	backend.buffer_copy_compute_readback(
		&engine.vk_ctx,
		frame.clusters.indices,
		frame.clusters.readback_indices,
		CLUSTER_INDEX_CAPACITY,
	)
	backend.buffer_copy_compute_readback(&engine.vk_ctx, frame.clusters.counter, frame.clusters.readback_counter, 1)
	backend.buffer_read(&engine.vk_ctx, frame.clusters.readback_headers, headers)
	backend.buffer_read(&engine.vk_ctx, frame.clusters.readback_indices, indices)
	backend.buffer_read(&engine.vk_ctx, frame.clusters.readback_counter, count_out)
	scene := make([]SceneData, 1, context.temp_allocator)
	backend.buffer_read(&engine.vk_ctx, frame.scene_data_buffer, scene)
	points := make([]GpuPointLight, int(scene[0].point_light_count), context.temp_allocator)
	spots := make([]GpuSpotLight, int(scene[0].spot_light_count), context.temp_allocator)
	if len(points) > 0 do backend.buffer_read(&engine.vk_ctx, frame.point_lights_buffer, points)
	if len(spots) > 0 do backend.buffer_read(&engine.vk_ctx, frame.spot_lights_buffer, spots)

	extent := render_extent(engine)
	proj := scene[0].proj
	view := scene[0].view
	inv_proj := linalg.inverse(proj)
	near_z, far_z := scene[0].cluster_near_far.x, scene[0].cluster_near_far.y
	assert(near_z > 0)
	forward_sign: f32 = 1
	if proj[3, 2] < 0 || (abs(proj[3, 2]) < 1e-6 && proj[2, 2] < 0) {forward_sign = -1}
	centers_checked, sample_points, misses_centers, misses_samples, hits, extras: u64
	for i in 0 ..< len(points) + len(spots) {
		var_index := u32(i)
		pos: Vec4
		if i < len(points) {pos = points[i].position_range} else {pos = spots[i - len(points)].position_range}
		clip := proj * (view * Vec4{pos.x, pos.y, pos.z, 1})
		if clip.w == 0 {continue}
		nx, ny, nz := clip.x / clip.w, clip.y / clip.w, clip.z / clip.w
		px, py := int((nx * 0.5 + 0.5) * f32(extent.width)), int((ny * 0.5 + 0.5) * f32(extent.height))
		view_center := view * Vec4{pos.x, pos.y, pos.z, 1}
		center_depth := view_center.z * forward_sign
		z := int(
			clamp(
				math.log_f32(max(center_depth, near_z) / near_z, 2) / math.log_f32(far_z / near_z, 2) * f32(CLUSTER_Z),
				0,
				f32(CLUSTER_Z - 1),
			),
		)
		cx, cy :=
			int(clamp(f32(px) / f32(extent.width) * f32(CLUSTER_X), 0, f32(CLUSTER_X - 1))),
			int(clamp(f32(py) / f32(extent.height) * f32(CLUSTER_Y), 0, f32(CLUSTER_Y - 1)))
		idx := var_index
		if i >= len(points) {idx = MAX_POINT_LIGHTS + u32(i - len(points))}
		if px >= 0 &&
		   py >= 0 &&
		   px < int(extent.width) &&
		   py < int(extent.height) &&
		   center_depth >= near_z &&
		   center_depth <= far_z {
			centers_checked += 1
			if !cluster_has(headers, indices, cx + cy * CLUSTER_X + z * CLUSTER_X * CLUSTER_Y, idx) do misses_centers += 1
		}
	}
	for py := 0; py < int(extent.height); py += 7 {
		for px := 0; px < int(extent.width); px += 7 {
			ndc := Vec4 {
				(f32(px) + 0.5) / f32(extent.width) * 2 - 1,
				(f32(py) + 0.5) / f32(extent.height) * 2 - 1,
				1,
				1,
			}
			far_point := inv_proj * ndc
			far_point.xyz /= far_point.w
			for zi in 0 ..< 16 {
				sample_points += 1
				depth := near_z * math.pow_f32(far_z / near_z, (f32(zi) + 0.5) / 16)
				view_point := far_point.xyz
				if abs(proj[3, 2]) < 1e-6 {
					if proj[2, 2] < 0 {view_point.z = -depth} else {view_point.z = depth}
				} else {
					view_point *= depth / abs(far_point.z)
				}
				world4 := linalg.inverse(view) * Vec4{view_point.x, view_point.y, view_point.z, 1}
				cx, cy := px * CLUSTER_X / int(extent.width), py * CLUSTER_Y / int(extent.height)
				cz := int(
					clamp(
						math.log_f32(depth / near_z, 2) / math.log_f32(far_z / near_z, 2) * f32(CLUSTER_Z),
						0,
						f32(CLUSTER_Z - 1),
					),
				)
				cluster := cx + cy * CLUSTER_X + cz * CLUSTER_X * CLUSTER_Y
				for li in 0 ..< len(points) {
					light := points[li]
					d := Vec3{world4.x, world4.y, world4.z} - light.position_range.xyz
					if linalg.dot(d, d) <=
					   light.position_range.w *
						   light.position_range.w {hits += 1; if !cluster_has(headers, indices, cluster, u32(li)) do misses_samples += 1}
				}
				for li in 0 ..< len(spots) {
					light := spots[li]
					d := Vec3{world4.x, world4.y, world4.z} - light.position_range.xyz
					if linalg.dot(d, d) <=
					   light.position_range.w *
						   light.position_range.w {hits += 1; if !cluster_has(headers, indices, cluster, MAX_POINT_LIGHTS + u32(li)) do misses_samples += 1}
				}
			}
		}
	}
	for c in 0 ..< len(headers) {
		header := headers[c]
		for item in indices[int(header.light_offset):][:int(header.light_count & 0x7fffffff)] {
			position: Vec3
			radius: f32
			if item < MAX_POINT_LIGHTS {
				if item >= u32(len(points)) {continue}
				light := points[item]
				position, radius = light.position_range.xyz, light.position_range.w
			} else {
				index := item - MAX_POINT_LIGHTS
				if index >= u32(len(spots)) {continue}
				light := spots[index]
				position, radius = light.position_range.xyz, light.position_range.w
			}
			if !cluster_sphere_overlaps(inv_proj, proj, view, near_z, far_z, c, position, radius) do extras += 1
		}
	}
	log.infof(
		"cluster validation: centers=%d centers_missed=%d sample_points=%d sampled_hits=%d sampled_missed=%d conservative_extra=%d indices=%d/%d overflow=%v extent=%dx%d",
		centers_checked,
		misses_centers,
		sample_points,
		hits,
		misses_samples,
		extras,
		count_out[0],
		CLUSTER_INDEX_CAPACITY,
		count_out[0] > CLUSTER_INDEX_CAPACITY,
		extent.width,
		extent.height,
	)
}

@(private = "file")
cluster_sphere_overlaps :: proc(
	inv_proj: Mat4x4,
	proj, view: Mat4x4,
	near_z, far_z: f32,
	cluster: int,
	position: Vec3,
	radius: f32,
) -> bool {
	x, y, z := cluster % CLUSTER_X, (cluster / CLUSTER_X) % CLUSTER_Y, cluster / (CLUSTER_X * CLUSTER_Y)
	z0 := near_z * math.pow_f32(far_z / near_z, f32(z) / f32(CLUSTER_Z))
	z1 := near_z * math.pow_f32(far_z / near_z, f32(z + 1) / f32(CLUSTER_Z))
	ortho := abs(proj[3, 2]) < 1e-6
	forward_sign: f32 = 1
	if proj[3, 2] < 0 || (ortho && proj[2, 2] < 0) {forward_sign = -1}
	lo := Vec3{3.402823e38, 3.402823e38, z0}
	hi := Vec3{-3.402823e38, -3.402823e38, z1}
	for corner in 0 ..< 8 {
		ndc_x := f32(x + corner % 2) / f32(CLUSTER_X) * 2 - 1
		ndc_y := f32(y + (corner / 2) % 2) / f32(CLUSTER_Y) * 2 - 1
		depth := z0
		if corner >= 4 {depth = z1}
		point := inv_proj * Vec4{ndc_x, ndc_y, 1, 1}
		point.xyz /= point.w
		if ortho {
			point.z = depth
		} else {
			point.xyz *= depth / abs(point.z)
			point.z = depth
		}
		lo.x, lo.y = min(lo.x, point.x), min(lo.y, point.y)
		hi.x, hi.y = max(hi.x, point.x), max(hi.y, point.y)
	}
	center4 := view * Vec4{position.x, position.y, position.z, 1}
	center := Vec3{center4.x, center4.y, center4.z * forward_sign}
	closest := Vec3{clamp(center.x, lo.x, hi.x), clamp(center.y, lo.y, hi.y), clamp(center.z, lo.z, hi.z)}
	d := center - closest
	return linalg.dot(d, d) <= radius * radius
}

package graphics

import "backend"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"

@(shader_shared)
CLUSTER_X :: 16
@(shader_shared)
CLUSTER_Y :: 9
@(shader_shared)
CLUSTER_Z :: 24
@(shader_shared)
CLUSTER_COUNT :: CLUSTER_X * CLUSTER_Y * CLUSTER_Z
@(shader_shared)
// Each cluster reserves the full legal light set. There is no overflow case; unused entries are
// ignored by light_count, and the header's light_offset is in u32 elements, not bytes.
CLUSTER_LIGHT_CAPACITY :: MAX_POINT_LIGHTS + MAX_SPOT_LIGHTS

@(shader_shared)
ClusterHeader :: struct #max_field_align(16) {
	light_offset: u32,
	light_count:  u32,
}

@(shader_shared)
ClusterPushConstants :: struct #max_field_align(16) {
	scene_data: backend.GPUPtr(SceneData),
	clusters:   backend.GPUPtr(ClusterHeader),
	indices:    backend.GPUPtr(u32),
	extent:     Vec2,
	near_far:   Vec2,
}

ClusterBuffers :: struct {
	headers: backend.Buffer(ClusterHeader),
	indices: backend.Buffer(u32),
}

cluster_buffers_create :: proc(engine: ^Engine) {
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		engine.frame_data[i].clusters.headers = backend.buffer_create(
			ClusterHeader,
			&engine.vk_ctx,
			CLUSTER_COUNT,
			{.Storage},
			.Shared,
		)
		engine.frame_data[i].clusters.indices = backend.buffer_create(
			u32,
			&engine.vk_ctx,
			CLUSTER_COUNT * CLUSTER_LIGHT_CAPACITY,
			{.Storage},
			.Shared,
		)
	}
}

cluster_buffers_destroy :: proc(engine: ^Engine) {
	for &frame in engine.frame_data {
		backend.buffer_destroy(&engine.vk_ctx, frame.clusters.headers)
		backend.buffer_destroy(&engine.vk_ctx, frame.clusters.indices)
	}
}

dispatch_clusters :: proc(engine: ^Engine, packet: ^FramePacket, cmd: backend.CommandBuffer) {
	frame := &engine.frame_data[backend.frame_slot(&engine.vk_ctx)]
	pc := ClusterPushConstants {
		scene_data = backend.buffer_address(&engine.vk_ctx, frame.scene_data_buffer),
		clusters   = backend.buffer_address(&engine.vk_ctx, frame.clusters.headers),
		indices    = backend.buffer_address(&engine.vk_ctx, frame.clusters.indices),
		extent     = {f32(render_extent(engine).width), f32(render_extent(engine).height)},
		near_far   = {packet.camera.near, packet.camera.far},
	}
	encoder := backend.begin_compute_pass(cmd)
	backend.pipeline_bind_compute(encoder, pipeline_get(engine, .Clusters))
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, CLUSTER_X, CLUSTER_Y, CLUSTER_Z)
	backend.cmd_barrier_compute_write_to_fragment_read(encoder)
	backend.end_compute_pass(encoder)
}

// One-shot debug audit for VEIL_CLUSTER_VALIDATE=1. Called after the frame fence, so the shared
// buffers can be invalidated and read safely. It compares each GPU list to a CPU sphere/AABB pass.
cluster_debug_validate :: proc(engine: ^Engine, camera: Camera) {
	value, found := os.lookup_env("VEIL_CLUSTER_VALIDATE", context.allocator)
	if !found do return
	defer delete(value)
	if value == "0" do return
	os.unset_env("VEIL_CLUSTER_VALIDATE")

	frame := current_frame_data(engine)
	headers := make([]ClusterHeader, CLUSTER_COUNT, context.temp_allocator)
	indices := make([]u32, CLUSTER_COUNT * CLUSTER_LIGHT_CAPACITY, context.temp_allocator)
	backend.buffer_read(&engine.vk_ctx, frame.clusters.headers, headers)
	backend.buffer_read(&engine.vk_ctx, frame.clusters.indices, indices)
	scene := make([]SceneData, 1, context.temp_allocator)
	backend.buffer_read(&engine.vk_ctx, frame.scene_data_buffer, scene)
	points := make([]GpuPointLight, int(scene[0].point_light_count), context.temp_allocator)
	spots := make([]GpuSpotLight, int(scene[0].spot_light_count), context.temp_allocator)
	if len(points) > 0 do backend.buffer_read(&engine.vk_ctx, frame.point_lights_buffer, points)
	if len(spots) > 0 do backend.buffer_read(&engine.vk_ctx, frame.spot_lights_buffer, spots)

	proj := scene[0].proj
	view := scene[0].view
	forward_sign: f32 = 1
	orthographic := abs(proj[3, 2]) < 1e-6
	if proj[3, 2] < 0 || (orthographic && proj[2, 2] < 0) do forward_sign = -1
	extent := render_extent(engine)
	misses, extras: u64
	for z in 0 ..< CLUSTER_Z {
		z0 := camera.near * math.pow(camera.far / camera.near, f32(z) / f32(CLUSTER_Z))
		z1 := camera.near * math.pow(camera.far / camera.near, f32(z + 1) / f32(CLUSTER_Z))
		for y in 0 ..< CLUSTER_Y {
			for x in 0 ..< CLUSTER_X {
				ndc_x0 := f32(x) / f32(CLUSTER_X) * 2 - 1
				ndc_x1 := f32(x + 1) / f32(CLUSTER_X) * 2 - 1
				ndc_y0 := 1 - f32(y + 1) / f32(CLUSTER_Y) * 2
				ndc_y1 := 1 - f32(y) / f32(CLUSTER_Y) * 2
				projection_scale := f32(1)
				if !orthographic do projection_scale = abs(proj[3, 2])
				sx, sy := projection_scale / proj[0, 0], projection_scale / proj[1, 1]
				lo := Vec3 {
					min(ndc_x0 * z0 * sx, ndc_x0 * z1 * sx, ndc_x1 * z0 * sx, ndc_x1 * z1 * sx),
					min(ndc_y0 * z0 * sy, ndc_y0 * z1 * sy, ndc_y1 * z0 * sy, ndc_y1 * z1 * sy),
					z0,
				}
				hi := Vec3 {
					max(ndc_x0 * z0 * sx, ndc_x0 * z1 * sx, ndc_x1 * z0 * sx, ndc_x1 * z1 * sx),
					max(ndc_y0 * z0 * sy, ndc_y0 * z1 * sy, ndc_y1 * z0 * sy, ndc_y1 * z1 * sy),
					z1,
				}
				cluster := x + y * CLUSTER_X + z * CLUSTER_X * CLUSTER_Y
				header := headers[cluster]
				for light, i in points do cluster_validate_light(indices, header, light.position_range.xyz, light.position_range.w, u32(i), view, forward_sign, lo, hi, &misses, &extras)
				for light, i in spots do cluster_validate_light(indices, header, light.position_range.xyz, light.position_range.w, MAX_POINT_LIGHTS + u32(i), view, forward_sign, lo, hi, &misses, &extras)
			}
		}
	}
	log.infof(
		"cluster CPU cross-check: missed=%d conservative_extra=%d clusters=%d extent=%dx%d",
		misses,
		extras,
		CLUSTER_COUNT,
		extent.width,
		extent.height,
	)
}

@(private = "file")
cluster_validate_light :: proc(
	indices: []u32,
	header: ClusterHeader,
	position: Vec3,
	radius: f32,
	index: u32,
	view: Mat4x4,
	forward_sign: f32,
	lo, hi: Vec3,
	misses, extras: ^u64,
) {
	p := view * Vec4{position.x, position.y, position.z, 1}
	center := Vec3{p.x, p.y, p.z * forward_sign}
	closest := Vec3{clamp(center.x, lo.x, hi.x), clamp(center.y, lo.y, hi.y), clamp(center.z, lo.z, hi.z)}
	delta := center - closest
	hit := linalg.dot(delta, delta) <= radius * radius
	present := false
	first, count := int(header.light_offset), int(header.light_count)
	for item in indices[first:][:count] {
		if item == index {
			present = true
			break
		}
	}
	if hit && !present do misses^ += 1
	if present && !hit do extras^ += 1
}

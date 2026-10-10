package graphics

import "backend"

@(shader_shared)
TonemapPushConstants :: struct #max_field_align(16) {
	hdr_texture:    TextureIndex, // bindless sampled index of the HDR image
	out_storage:    StorageImageIndex, // bindless storage index of the LDR draw image
	exposure:       f32,
	bloom_texture:  TextureIndex, // bindless sampled index of bloom mip 0 (half res)
	bloom_strength: f32, // pre-normalized: setting / bloom level count
}

// Shared by the bloom downsample and upsample passes.
@(shader_shared)
BloomPushConstants :: struct #max_field_align(16) {
	src_texture:    TextureIndex, // bindless sampled index of the mip (or hdr) being read
	dst_storage:    StorageImageIndex, // bindless storage index of the mip being written
	src_texel_size: Vec2, // 1 / source size, for sample offsets
	karis:          u32, // downsample only: 1 on the first pass (reading hdr)
	radius:         f32, // upsample only: tent filter radius, in source texels
}

TONEMAP_EXPOSURE :: 1.0 // default for PostSettings.exposure
@(shader_shared)
POST_GROUP_SIZE :: 8

BLOOM_DEFAULT_LEVELS :: 6
BLOOM_DEFAULT_STRENGTH :: 0.15
// The chain stops before the smallest mip's short side would drop below this, so the glow keeps
// roughly the same share of the screen at any resolution and never collapses into a 1x1 haze.
BLOOM_MIN_MIP_SIZE :: 8
BLOOM_UPSAMPLE_RADIUS :: 1.0

// Post-processing settings. They ride on the camera: indoor, outdoor and cutscene cameras want
// different values.
PostSettings :: struct {
	exposure:         f32,
	bloom_strength:   f32,
	bloom_max_levels: u32, // bloom_levels clamps it to the screen and the bloom target
}

POST_SETTINGS_DEFAULT :: PostSettings {
	exposure         = TONEMAP_EXPOSURE,
	bloom_strength   = BLOOM_DEFAULT_STRENGTH,
	bloom_max_levels = BLOOM_DEFAULT_LEVELS,
}

// Active bloom levels: as many as fit before a mip's short side drops below BLOOM_MIN_MIP_SIZE,
// capped by max_levels and by what the bloom target was allocated with.
bloom_levels :: proc(engine: ^Engine, max_levels: u32) -> u32 {
	bloom := backend.image_desc(&engine.vk_ctx, engine.render_targets.bloom)
	short_side := min(bloom.extent.width, bloom.extent.height)
	for_screen: u32 = 1
	for (short_side >> for_screen) >= BLOOM_MIN_MIP_SIZE do for_screen += 1
	return max(min(for_screen, max_levels, bloom.mip_levels), 1)
}

@(private = "file")
mip_extent :: proc(desc: backend.ImageDesc, mip: u32) -> [2]u32 {
	return {max(desc.extent.width >> mip, 1), max(desc.extent.height >> mip, 1)}
}

@(private = "file")
dispatch_post :: proc(encoder: backend.ComputeEncoder, size: [2]u32) {
	backend.cmd_dispatch(
		encoder,
		(size.x + POST_GROUP_SIZE - 1) / POST_GROUP_SIZE,
		(size.y + POST_GROUP_SIZE - 1) / POST_GROUP_SIZE,
		1,
	)
}

// CoD:AW-style chain. Downsamples hdr -> mip 0 -> ... -> mip L-1 (each overwrites its target),
// then upsamples back up, each step adding the smaller mip into the next larger one. Mip 0 ends
// up holding every blur radius and is what the tonemap composites.
dispatch_bloom :: proc(engine: ^Engine, packet: ^FramePacket, cmd: backend.CommandBuffer) {
	targets := &engine.render_targets
	bloom := targets.bloom
	bloom_desc := backend.image_desc(&engine.vk_ctx, bloom)
	hdr_extent := backend.image_desc(&engine.vk_ctx, targets.hdr).extent
	color := backend.ImageAspectFlags{.Color}
	levels := bloom_levels(engine, packet.camera.post.bloom_max_levels)

	encoder := backend.begin_compute_pass(cmd)
	defer backend.end_compute_pass(encoder)

	down := pipeline_get(engine, .Bloom_Down)
	backend.pipeline_bind_compute(encoder, down)
	for i in 0 ..< levels {
		src_size: [2]u32
		pc := BloomPushConstants {
			dst_storage = StorageImageIndex(STORAGE_SLOT_BLOOM + i),
		}
		if i == 0 {
			src_size = {hdr_extent.width, hdr_extent.height}
			pc.src_texture = texture_index(targets.hdr_texture)
			pc.karis = 1
		} else {
			backend.image_barrier(encoder, bloom, .Shader_Read, color, base_mip_level = i - 1)
			src_size = mip_extent(bloom_desc, i - 1)
			pc.src_texture = texture_index(targets.bloom_textures[i - 1])
		}
		pc.src_texel_size = {1 / f32(src_size.x), 1 / f32(src_size.y)}
		backend.image_barrier(encoder, bloom, .General, color, base_mip_level = i)
		backend.pipeline_push_compute(encoder, &pc)
		dispatch_post(encoder, mip_extent(bloom_desc, i))
	}

	up := pipeline_get(engine, .Bloom_Up)
	backend.pipeline_bind_compute(encoder, up)
	for i := int(levels) - 2; i >= 0; i -= 1 {
		dst := u32(i)
		src := dst + 1
		src_size := mip_extent(bloom_desc, src)
		backend.image_barrier(encoder, bloom, .Shader_Read, color, base_mip_level = src)
		// dst was last read by the downsample into src; the upsample reads and writes it in place.
		backend.image_barrier(encoder, bloom, .General, color, base_mip_level = dst)
		pc := BloomPushConstants {
			src_texture    = texture_index(targets.bloom_textures[src]),
			dst_storage    = StorageImageIndex(STORAGE_SLOT_BLOOM + dst),
			src_texel_size = {1 / f32(src_size.x), 1 / f32(src_size.y)},
			radius         = BLOOM_UPSAMPLE_RADIUS,
		}
		backend.pipeline_push_compute(encoder, &pc)
		dispatch_post(encoder, mip_extent(bloom_desc, dst))
	}

	// The tonemap samples mip 0.
	backend.image_barrier(encoder, bloom, .Shader_Read, color, base_mip_level = 0)
}

// Tonemaps the HDR target (plus bloom) into the LDR draw target. Everything drawn into draw
// afterwards (debug view, UI) skips the tonemap, and present_blit only has to sRGB-encode.
dispatch_tonemap :: proc(engine: ^Engine, packet: ^FramePacket, cmd: backend.CommandBuffer) {
	targets := &engine.render_targets
	post := packet.camera.post

	pipeline := pipeline_get(engine, .Tonemap)
	pc := TonemapPushConstants {
		hdr_texture    = texture_index(targets.hdr_texture),
		out_storage    = STORAGE_SLOT_DRAW,
		exposure       = post.exposure,
		bloom_texture  = texture_index(targets.bloom_textures[0]),
		bloom_strength = post.bloom_strength / f32(bloom_levels(engine, post.bloom_max_levels)),
	}

	encoder := backend.begin_compute_pass(cmd)
	backend.pipeline_bind_compute(encoder, pipeline)
	backend.pipeline_push_compute(encoder, &pc)
	extent := render_extent(engine)
	dispatch_post(encoder, {extent.width, extent.height})
	backend.end_compute_pass(encoder)
}

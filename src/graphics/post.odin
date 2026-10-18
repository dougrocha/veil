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

// Mip sizes are computed once while building, so recording needs no image queries.
BloomPass :: struct {
	levels:    u32,
	hdr_size:  [2]u32,
	mip_sizes: [BLOOM_MAX_MIPS][2]u32,
}

// The tonemap dispatch size and its exposure and bloom inputs.
TonemapPass :: struct {
	size:                     [2]u32,
	exposure, bloom_strength: f32,
}

// Active bloom levels: as many as fit before a mip's short side drops below BLOOM_MIN_MIP_SIZE,
// capped by max_levels and by what the bloom target was allocated with.
bloom_level_count :: proc(targets: TargetInfo, max_levels: u32) -> u32 {
	short_side := min(targets.bloom_extent.width, targets.bloom_extent.height)
	for_screen: u32 = 1
	for (short_side >> for_screen) >= BLOOM_MIN_MIP_SIZE do for_screen += 1
	return max(min(for_screen, max_levels, targets.bloom_mips), 1)
}

// Sizes the bloom chain from the screen and the bloom target, and the tonemap that composites it.
// The level count is computed once and feeds both: bloom_strength is pre-divided by it, matching the
// push constant.
post_passes_build :: proc(targets: TargetInfo, post: PostSettings) -> (BloomPass, TonemapPass) {
	levels := bloom_level_count(targets, post.bloom_max_levels)
	bloom := BloomPass {
		levels   = levels,
		hdr_size = {targets.extent.width, targets.extent.height},
	}
	for i in 0 ..< BLOOM_MAX_MIPS {
		bloom.mip_sizes[i] = {
			max(targets.bloom_extent.width >> u32(i), 1),
			max(targets.bloom_extent.height >> u32(i), 1),
		}
	}
	tonemap := TonemapPass {
		size           = {targets.extent.width, targets.extent.height},
		exposure       = post.exposure,
		bloom_strength = post.bloom_strength / f32(levels),
	}
	return bloom, tonemap
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
record_bloom :: proc(r: ^Recorder, p: ^BloomPass) {
	targets := r.targets
	bloom := targets.bloom
	color := backend.ImageAspectFlags{.Color}
	levels := p.levels

	encoder := backend.begin_compute_pass(r.cmd)
	defer backend.end_compute_pass(encoder)

	down := rec_pipeline(r, .Bloom_Down)
	backend.pipeline_bind_compute(encoder, down)
	for i in 0 ..< levels {
		src_size: [2]u32
		pc := BloomPushConstants {
			dst_storage = StorageImageIndex(STORAGE_SLOT_BLOOM + i),
		}
		if i == 0 {
			src_size = p.hdr_size
			pc.src_texture = texture_index(targets.hdr_texture)
			pc.karis = 1
		} else {
			backend.image_barrier(encoder, bloom, .Shader_Read, color, base_mip_level = i - 1)
			src_size = p.mip_sizes[i - 1]
			pc.src_texture = texture_index(targets.bloom_textures[i - 1])
		}
		pc.src_texel_size = {1 / f32(src_size.x), 1 / f32(src_size.y)}
		backend.image_barrier(encoder, bloom, .General, color, base_mip_level = i)
		backend.pipeline_push_compute(encoder, &pc)
		dispatch_post(encoder, p.mip_sizes[i])
	}

	up := rec_pipeline(r, .Bloom_Up)
	backend.pipeline_bind_compute(encoder, up)
	for i := int(levels) - 2; i >= 0; i -= 1 {
		dst := u32(i)
		src := dst + 1
		src_size := p.mip_sizes[src]
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
		dispatch_post(encoder, p.mip_sizes[dst])
	}

	// The tonemap samples mip 0.
	backend.image_barrier(encoder, bloom, .Shader_Read, color, base_mip_level = 0)
}

// Tonemaps the HDR target (plus bloom) into the LDR draw target. Everything drawn into draw
// afterwards (debug view, UI) skips the tonemap, and present_blit only has to sRGB-encode.
record_tonemap :: proc(r: ^Recorder, post: ^TonemapPass) {
	targets := r.targets

	pipeline := rec_pipeline(r, .Tonemap)
	pc := TonemapPushConstants {
		hdr_texture    = texture_index(targets.hdr_texture),
		out_storage    = STORAGE_SLOT_DRAW,
		exposure       = post.exposure,
		bloom_texture  = texture_index(targets.bloom_textures[0]),
		bloom_strength = post.bloom_strength,
	}

	encoder := backend.begin_compute_pass(r.cmd)
	backend.pipeline_bind_compute(encoder, pipeline)
	backend.pipeline_push_compute(encoder, &pc)
	dispatch_post(encoder, post.size)
	backend.end_compute_pass(encoder)
}

// A game-side display query; the frame build uses the same sizing rule without device access.
bloom_levels :: proc(engine: ^Engine, max_levels: u32) -> u32 {
	desc := backend.image_desc(&engine.vk_ctx, engine.render_targets.bloom)
	targets := TargetInfo {
		extent       = engine.render_targets.extent,
		bloom_extent = {desc.extent.width, desc.extent.height},
		bloom_mips   = desc.mip_levels,
	}
	return bloom_level_count(targets, max_levels)
}

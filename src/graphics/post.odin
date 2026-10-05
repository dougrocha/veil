package graphics

import "core:fmt"

import "backend"

TONEMAP_EXPOSURE :: 1.0 // default for debug_settings.exposure
// Keep in sync with numthreads in tonemap.slang, bloom_down.slang and bloom_up.slang.
POST_GROUP_SIZE :: 8

BLOOM_DEFAULT_LEVELS :: 6
BLOOM_DEFAULT_STRENGTH :: 0.15
// The chain stops before the smallest mip's short side would drop below this, so the glow keeps
// roughly the same share of the screen at any resolution and never collapses into a 1x1 haze.
BLOOM_MIN_MIP_SIZE :: 8
BLOOM_UPSAMPLE_RADIUS :: 1.0

// Active bloom levels: as many as fit before a mip's short side drops below BLOOM_MIN_MIP_SIZE,
// capped by the debug setting and by what the bloom target was allocated with.
bloom_levels :: proc(engine: ^Engine) -> u32 {
	bloom := backend.image_desc(&engine.vk_ctx, engine.render_targets.bloom)
	short_side := min(bloom.extent.width, bloom.extent.height)
	for_screen: u32 = 1
	for (short_side >> for_screen) >= BLOOM_MIN_MIP_SIZE do for_screen += 1
	return max(min(for_screen, engine.debug_settings.bloom_max_levels, bloom.mip_levels), 1)
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
		{POST_GROUP_SIZE, POST_GROUP_SIZE, 1},
	)
}

// CoD:AW-style chain. Downsamples hdr -> mip 0 -> ... -> mip L-1 (each overwrites its target),
// then upsamples back up, each step adding the smaller mip into the next larger one. Mip 0 ends
// up holding every blur radius and is what the tonemap composites.
dispatch_bloom :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	targets := &engine.render_targets
	bloom := targets.bloom
	bloom_desc := backend.image_desc(&engine.vk_ctx, bloom)
	hdr_extent := backend.image_desc(&engine.vk_ctx, targets.hdr).extent
	color := backend.ImageAspectFlags{.Color}
	levels := bloom_levels(engine)

	backend.image_barrier(cmd, targets.hdr, .Shader_Read, color)

	encoder := backend.begin_compute_pass(&engine.vk_ctx, cmd)
	defer backend.end_compute_pass(encoder)

	down := compute_pipeline(engine, .Bloom_Down)
	backend.pipeline_bind_compute(encoder, down)
	for i in 0 ..< levels {
		src_size: [2]u32
		pc := BloomPushConstants {
			dst_storage = STORAGE_SLOT_BLOOM + i,
		}
		if i == 0 {
			src_size = {hdr_extent.width, hdr_extent.height}
			pc.src_texture = u32(targets.hdr_texture.index)
			pc.karis = 1
		} else {
			backend.image_barrier(encoder, bloom, .Shader_Read, color, base_mip_level = i - 1)
			src_size = mip_extent(bloom_desc, i - 1)
			pc.src_texture = u32(targets.bloom_textures[i - 1].index)
		}
		pc.src_texel_size = {1 / f32(src_size.x), 1 / f32(src_size.y)}
		backend.image_barrier(encoder, bloom, .General, color, base_mip_level = i)
		backend.pipeline_push_compute(encoder, &pc)
		dispatch_post(encoder, mip_extent(bloom_desc, i))
	}

	up := compute_pipeline(engine, .Bloom_Up)
	backend.pipeline_bind_compute(encoder, up)
	for i := int(levels) - 2; i >= 0; i -= 1 {
		dst := u32(i)
		src := dst + 1
		src_size := mip_extent(bloom_desc, src)
		backend.image_barrier(encoder, bloom, .Shader_Read, color, base_mip_level = src)
		// dst was last read by the downsample into src; the upsample reads and writes it in place.
		backend.image_barrier(encoder, bloom, .General, color, base_mip_level = dst)
		pc := BloomPushConstants {
			src_texture    = u32(targets.bloom_textures[src].index),
			dst_storage    = STORAGE_SLOT_BLOOM + dst,
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
dispatch_tonemap :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	targets := &engine.render_targets
	backend.image_barrier(cmd, targets.hdr, .Shader_Read, backend.ImageAspectFlags{.Color})
	backend.image_barrier(cmd, targets.draw, .General, backend.ImageAspectFlags{.Color})

	pipeline := compute_pipeline(engine, .Tonemap)
	pc := TonemapPushConstants {
		hdr_texture    = u32(targets.hdr_texture.index),
		out_storage    = STORAGE_SLOT_DRAW,
		exposure       = engine.debug_settings.exposure,
		bloom_texture  = u32(targets.bloom_textures[0].index),
		bloom_strength = engine.debug_settings.bloom_strength / f32(bloom_levels(engine)),
	}

	encoder := backend.begin_compute_pass(&engine.vk_ctx, cmd)
	backend.pipeline_bind_compute(encoder, pipeline)
	backend.pipeline_push_compute(encoder, &pc)
	extent := render_extent(engine)
	dispatch_post(encoder, {extent.width, extent.height})
	backend.end_compute_pass(encoder)
}

EXPOSURE_STEP :: 0.25
BLOOM_STRENGTH_STEP :: 0.05

// Left/Right: selects the next or previous post value (dir = +1 / -1), wrapping around.
post_control_cycle :: proc(engine: ^Engine, dir: int) {
	n := len(PostControl)
	s := &engine.debug_settings
	s.post_control = PostControl((int(s.post_control) + dir + n) % n)
}

// Up/Down: steps the selected post value (dir = +1 / -1), clamped to its valid range.
post_control_step :: proc(engine: ^Engine, dir: int) {
	s := &engine.debug_settings
	switch s.post_control {
	case .Exposure:
		s.exposure = max(s.exposure + f32(dir) * EXPOSURE_STEP, 0)
	case .Bloom_Strength:
		s.bloom_strength = max(s.bloom_strength + f32(dir) * BLOOM_STRENGTH_STEP, 0)
	case .Bloom_Levels:
		s.bloom_max_levels = u32(clamp(int(s.bloom_max_levels) + dir, 1, BLOOM_MAX_MIPS))
	}
}

// Stats line for the post values; ">" marks the one the arrow keys adjust. Levels shows the
// setting and what actually runs after the resolution clamp.
post_control_line :: proc(engine: ^Engine) -> string {
	s := &engine.debug_settings
	mark :: proc(s: ^DebugSettings, c: PostControl) -> string {
		return ">" if s.post_control == c else " "
	}
	return fmt.tprintf(
		"post %sexposure %.2f  %sbloom %.2f  %slevels %d/%d",
		mark(s, .Exposure),
		s.exposure,
		mark(s, .Bloom_Strength),
		s.bloom_strength,
		mark(s, .Bloom_Levels),
		s.bloom_max_levels,
		bloom_levels(engine),
	)
}

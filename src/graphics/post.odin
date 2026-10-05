package graphics

import "backend"

// Fixed slots in the bindless storage array (storage_descriptor, set 1 of compute post passes).
STORAGE_SLOT_DRAW :: 0
STORAGE_SLOT_BLOOM :: 1 // bloom mip i is at STORAGE_SLOT_BLOOM + i
#assert(STORAGE_SLOT_BLOOM + backend.BLOOM_MAX_MIPS <= BINDLESS_STORAGE_IMAGE_COUNT)

TONEMAP_EXPOSURE :: 1.0
// Keep in sync with numthreads in tonemap.slang, bloom_down.slang and bloom_up.slang.
POST_GROUP_SIZE :: 8

BLOOM_DEFAULT_LEVELS :: 6
BLOOM_DEFAULT_STRENGTH :: 0.15
// The chain stops before the smallest mip's short side would drop below this, so the glow keeps
// roughly the same share of the screen at any resolution and never collapses into a 1x1 haze.
BLOOM_MIN_MIP_SIZE :: 8
BLOOM_UPSAMPLE_RADIUS :: 1.0

post_targets_create :: proc(engine: ^Engine) {
	engine.storage_descriptor = backend.descriptor_set_create_bindless_storage(
		&engine.vk_ctx,
		BINDLESS_STORAGE_IMAGE_COUNT,
	)
	targets := &engine.swapchain.render_targets
	engine.hdr_texture = texture_register_external(engine, &targets.hdr)
	for &handle, i in engine.bloom_textures {
		handle = texture_register_external(engine, &targets.bloom, bloom_slot_mip(&targets.bloom, u32(i)))
	}
	storage_images_write(engine)
}

// Must run after swapchain_recreate, which destroys and recreates the render targets and
// their views. Texture handles and storage slots stay the same; only the descriptors change.
post_targets_update :: proc(engine: ^Engine) {
	targets := &engine.swapchain.render_targets
	texture_update_external(engine, engine.hdr_texture, &targets.hdr)
	for handle, i in engine.bloom_textures {
		texture_update_external(engine, handle, &targets.bloom, bloom_slot_mip(&targets.bloom, u32(i)))
	}
	storage_images_write(engine)
}

// Every bloom slot needs a valid view, but a tiny window allocates fewer than BLOOM_MAX_MIPS
// levels. Slots past the last level alias it; bloom_levels never dispatches them.
@(private = "file")
bloom_slot_mip :: proc(bloom: ^backend.GpuImage, slot: u32) -> u32 {
	return min(slot, bloom.mip_levels - 1)
}

@(private = "file")
storage_images_write :: proc(engine: ^Engine) {
	targets := &engine.swapchain.render_targets
	backend.descriptor_write_bindless_storage(
		&engine.vk_ctx,
		&engine.storage_descriptor,
		STORAGE_SLOT_DRAW,
		&targets.draw,
	)
	for i in 0 ..< u32(backend.BLOOM_MAX_MIPS) {
		backend.descriptor_write_bindless_storage(
			&engine.vk_ctx,
			&engine.storage_descriptor,
			STORAGE_SLOT_BLOOM + i,
			&targets.bloom,
			bloom_slot_mip(&targets.bloom, i),
		)
	}
}

// Active bloom levels: as many as fit before a mip's short side drops below BLOOM_MIN_MIP_SIZE,
// capped by the debug setting and by what the bloom target was allocated with.
bloom_levels :: proc(engine: ^Engine) -> u32 {
	bloom := &engine.swapchain.render_targets.bloom
	short_side := min(bloom.extent.width, bloom.extent.height)
	for_screen: u32 = 1
	for (short_side >> for_screen) >= BLOOM_MIN_MIP_SIZE do for_screen += 1
	return max(min(for_screen, engine.debug_settings.bloom_max_levels, bloom.mip_levels), 1)
}

@(private = "file")
mip_extent :: proc(img: ^backend.GpuImage, mip: u32) -> [2]u32 {
	return {max(img.extent.width >> mip, 1), max(img.extent.height >> mip, 1)}
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

@(private = "file")
bind_post_sets :: proc(engine: ^Engine, encoder: backend.ComputeEncoder, pipeline: backend.Pipeline) {
	frame_idx := current_frame_res_index(engine)
	backend.pipeline_bind_compute(
		encoder,
		pipeline,
		{engine.texture_system.descriptor.sets[frame_idx], engine.storage_descriptor.sets[frame_idx]},
	)
}

// CoD:AW-style chain. Downsamples hdr -> mip 0 -> ... -> mip L-1 (each overwrites its target),
// then upsamples back up, each step adding the smaller mip into the next larger one. Mip 0 ends
// up holding every blur radius and is what the tonemap composites.
dispatch_bloom :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	targets := &engine.swapchain.render_targets
	bloom := &targets.bloom
	color := backend.ImageAspectFlags{.Color}
	levels := bloom_levels(engine)

	backend.image_barrier(cmd, &targets.hdr, .Shader_Read, color)

	encoder := backend.begin_compute_pass(&engine.vk_ctx, cmd)
	defer backend.end_compute_pass(encoder)

	down := get_pipeline(&engine.pipeline_registry, .Bloom_Down_Compute)
	bind_post_sets(engine, encoder, down)
	for i in 0 ..< levels {
		src_size: [2]u32
		pc := BloomPushConstants {
			dst_storage = STORAGE_SLOT_BLOOM + i,
		}
		if i == 0 {
			src_size = {targets.hdr.extent.width, targets.hdr.extent.height}
			pc.src_texture = u32(engine.hdr_texture.index)
			pc.karis = 1
		} else {
			backend.image_barrier(cmd, bloom, .Shader_Read, color, base_mip_level = i - 1)
			src_size = mip_extent(bloom, i - 1)
			pc.src_texture = u32(engine.bloom_textures[i - 1].index)
		}
		pc.src_texel_size = {1 / f32(src_size.x), 1 / f32(src_size.y)}
		backend.image_barrier(cmd, bloom, .General, color, base_mip_level = i)
		backend.pipeline_push_compute(encoder, down, &pc)
		dispatch_post(encoder, mip_extent(bloom, i))
	}

	up := get_pipeline(&engine.pipeline_registry, .Bloom_Up_Compute)
	bind_post_sets(engine, encoder, up)
	for i := int(levels) - 2; i >= 0; i -= 1 {
		dst := u32(i)
		src := dst + 1
		src_size := mip_extent(bloom, src)
		backend.image_barrier(cmd, bloom, .Shader_Read, color, base_mip_level = src)
		// dst was last read by the downsample into src; the upsample reads and writes it in place.
		backend.image_barrier(cmd, bloom, .General, color, base_mip_level = dst)
		pc := BloomPushConstants {
			src_texture    = u32(engine.bloom_textures[src].index),
			dst_storage    = STORAGE_SLOT_BLOOM + dst,
			src_texel_size = {1 / f32(src_size.x), 1 / f32(src_size.y)},
			radius         = BLOOM_UPSAMPLE_RADIUS,
		}
		backend.pipeline_push_compute(encoder, up, &pc)
		dispatch_post(encoder, mip_extent(bloom, dst))
	}

	// The tonemap samples mip 0.
	backend.image_barrier(cmd, bloom, .Shader_Read, color, base_mip_level = 0)
}

// Tonemaps the HDR target (plus bloom) into the LDR draw target. Everything drawn into draw
// afterwards (debug view, UI) skips the tonemap, and present_blit only has to sRGB-encode.
dispatch_tonemap :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	targets := &engine.swapchain.render_targets
	backend.image_barrier(cmd, &targets.hdr, .Shader_Read, backend.ImageAspectFlags{.Color})
	backend.image_barrier(cmd, &targets.draw, .General, backend.ImageAspectFlags{.Color})

	pipeline := get_pipeline(&engine.pipeline_registry, .Tonemap_Compute)
	pc := TonemapPushConstants {
		hdr_texture    = u32(engine.hdr_texture.index),
		out_storage    = STORAGE_SLOT_DRAW,
		exposure       = TONEMAP_EXPOSURE,
		bloom_texture  = u32(engine.bloom_textures[0].index),
		bloom_strength = engine.debug_settings.bloom_strength / f32(bloom_levels(engine)),
	}

	encoder := backend.begin_compute_pass(&engine.vk_ctx, cmd)
	bind_post_sets(engine, encoder, pipeline)
	backend.pipeline_push_compute(encoder, pipeline, &pc)
	dispatch_post(encoder, {engine.swapchain.extent.width, engine.swapchain.extent.height})
	backend.end_compute_pass(encoder)
}

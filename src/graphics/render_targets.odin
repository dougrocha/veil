package graphics

import "backend"

RenderTargets :: struct {
	extent:         backend.Extent2D,
	color:          backend.Image,
	depth:          backend.Image,
	hdr:            backend.Image, // main pass resolve target, sampled by the tonemap
	draw:           backend.Image, // tonemapped LDR result; UI draws on top, then it's blitted to the swapchain
	bloom:          backend.Image, // half-res mip chain; mip_levels may be below BLOOM_MAX_MIPS for tiny windows

	// Texture handles for the sampled targets. They keep their bindless slots across resizes; only
	// the image behind them changes.
	hdr_texture:    TextureHandle,
	bloom_textures: [BLOOM_MAX_MIPS]TextureHandle, // one per bloom mip
}

BLOOM_MAX_MIPS :: 8

// Fixed slots in the bindless storage array.
STORAGE_SLOT_DRAW :: 0
STORAGE_SLOT_BLOOM :: 1 // bloom mip i is at STORAGE_SLOT_BLOOM + i
#assert(STORAGE_SLOT_BLOOM + BLOOM_MAX_MIPS <= BINDLESS_STORAGE_IMAGE_COUNT)

// Creates the targets at the swapchain's extent and gives them their texture and storage slots.
// Needs the texture system.
render_targets_create :: proc(engine: ^Engine) {
	targets := &engine.render_targets
	targets^ = render_targets_images_create(&engine.vk_ctx, engine.swapchain.extent)
	targets.hdr_texture = texture_register_external(engine, targets.hdr)
	bloom_mips := backend.image_desc(&engine.vk_ctx, targets.bloom).mip_levels
	for &handle, i in targets.bloom_textures {
		handle = texture_register_external(engine, targets.bloom, bloom_slot_mip(bloom_mips, u32(i)))
	}
	storage_images_write(engine)
}

// Destroys the images and frees their texture handles. Call before texture_system_destroy.
render_targets_destroy :: proc(engine: ^Engine) {
	targets := &engine.render_targets
	texture_unregister_external(engine, targets.hdr_texture)
	for handle in targets.bloom_textures do texture_unregister_external(engine, handle)
	render_targets_images_destroy(&engine.vk_ctx, targets)
}

// The size the passes draw at. Everything that draws or maps into screen space uses it.
render_extent :: proc(engine: ^Engine) -> backend.Extent2D {
	return engine.render_targets.extent
}

// The render extent as a float vector, for screen-space math (UI, lines, picking).
render_viewport :: proc(engine: ^Engine) -> Vec2 {
	extent := render_extent(engine)
	return {f32(extent.width), f32(extent.height)}
}

render_aspect :: proc(engine: ^Engine) -> f32 {
	extent := render_extent(engine)
	return f32(extent.width) / f32(extent.height)
}

// Call once per frame after frame_begin. When the swapchain was recreated at a new extent, recreates
// the targets at that extent and points their texture handles and storage slots at the new images.
// Waits for idle on resize: in-flight frames may still read the slots being rewritten.
render_targets_sync :: proc(engine: ^Engine) {
	targets := &engine.render_targets
	if targets.extent == engine.swapchain.extent do return

	backend.device_wait_idle(&engine.vk_ctx)
	render_targets_images_destroy(&engine.vk_ctx, targets)
	images := render_targets_images_create(&engine.vk_ctx, engine.swapchain.extent)
	images.hdr_texture = targets.hdr_texture
	images.bloom_textures = targets.bloom_textures
	targets^ = images

	texture_update_external(engine, targets.hdr_texture, targets.hdr)
	bloom_mips := backend.image_desc(&engine.vk_ctx, targets.bloom).mip_levels
	for handle, i in targets.bloom_textures {
		texture_update_external(engine, handle, targets.bloom, bloom_slot_mip(bloom_mips, u32(i)))
	}
	storage_images_write(engine)
}

@(private = "file")
render_targets_images_create :: proc(ctx: ^backend.Context, extent: backend.Extent2D) -> RenderTargets {
	extent_3d := backend.Extent3D{extent.width, extent.height, 1}
	return RenderTargets {
		extent = extent,
		bloom = bloom_target_create(ctx, extent),
		color = backend.render_target_create(
			ctx,
			extent_3d,
			backend.DRAW_FORMAT,
			{.Transient, .ColorAttachment},
			samples = ctx.msaa_samples,
		),
		depth = backend.render_target_create(
			ctx,
			extent_3d,
			backend.DEPTH_FORMAT,
			{.DepthStencilAttachment},
			samples = ctx.msaa_samples,
		),
		hdr = backend.render_target_create(ctx, extent_3d, backend.DRAW_FORMAT, {.ColorAttachment, .Sampled}),
		draw = backend.render_target_create(
			ctx,
			extent_3d,
			backend.DRAW_FORMAT,
			{.ColorAttachment, .TransferSrc, .TransferDst, .Storage},
		),
	}
}

@(private = "file")
render_targets_images_destroy :: proc(ctx: ^backend.Context, targets: ^RenderTargets) {
	backend.image_destroy(ctx, targets.color)
	backend.image_destroy(ctx, targets.depth)
	backend.image_destroy(ctx, targets.hdr)
	backend.image_destroy(ctx, targets.draw)
	backend.image_destroy(ctx, targets.bloom)
}

// Main scene pass: MSAA color (resolved into hdr) + depth. Meshes, skybox, particles, lines.
main_pass_layout :: proc(ctx: ^backend.Context, targets: ^RenderTargets) -> backend.AttachmentLayout {
	color := backend.image_desc(ctx, targets.color)
	depth := backend.image_desc(ctx, targets.depth)
	assert(color.samples == depth.samples)
	return {color = {0 = color.format}, color_count = 1, depth = depth.format, samples = color.samples}
}

// Overlay passes drawn straight into draw after the tonemap: UI, debug view. No depth.
overlay_pass_layout :: proc(ctx: ^backend.Context, targets: ^RenderTargets) -> backend.AttachmentLayout {
	draw := backend.image_desc(ctx, targets.draw)
	return {color = {0 = draw.format}, color_count = 1, depth = .Undefined, samples = draw.samples}
}

@(private = "file")
bloom_target_create :: proc(ctx: ^backend.Context, extent: backend.Extent2D) -> backend.Image {
	half := backend.Extent3D{max(extent.width / 2, 1), max(extent.height / 2, 1), 1}
	// A full chain for the short side has floor(log2(short)) + 1 levels.
	full_chain: u32 = 1
	for (min(half.width, half.height) >> full_chain) > 0 do full_chain += 1

	desc := backend.image_desc_default(half, backend.DRAW_FORMAT, {.Storage, .Sampled})
	desc.mip_levels = min(BLOOM_MAX_MIPS, full_chain)
	return backend.image_create(ctx, desc)
}

// Every bloom slot needs a valid view, but a tiny window allocates fewer than BLOOM_MAX_MIPS
// levels. Slots past the last level alias it; bloom_levels never dispatches them.
@(private = "file")
bloom_slot_mip :: proc(mip_levels: u32, slot: u32) -> u32 {
	return min(slot, mip_levels - 1)
}

@(private = "file")
storage_images_write :: proc(engine: ^Engine) {
	targets := &engine.render_targets
	bloom_mips := backend.image_desc(&engine.vk_ctx, targets.bloom).mip_levels
	backend.bindless_write_storage(&engine.vk_ctx, STORAGE_SLOT_DRAW, targets.draw)
	for i in 0 ..< u32(BLOOM_MAX_MIPS) {
		backend.bindless_write_storage(
			&engine.vk_ctx,
			STORAGE_SLOT_BLOOM + i,
			targets.bloom,
			bloom_slot_mip(bloom_mips, i),
		)
	}
}

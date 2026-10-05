package graphics

import "backend"

RenderTargets :: struct {
	extent: backend.Extent2D,
	color:  backend.Image,
	depth:  backend.Image,
	hdr:    backend.Image, // main pass resolve target, sampled by the tonemap
	draw:   backend.Image, // tonemapped LDR result; UI draws on top, then it's blitted to the swapchain
	bloom:  backend.Image, // half-res mip chain; mip_levels may be below BLOOM_MAX_MIPS for tiny windows
}

BLOOM_MAX_MIPS :: 8

render_targets_create :: proc(ctx: ^backend.Context, extent: backend.Extent2D) -> RenderTargets {
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

render_targets_destroy :: proc(ctx: ^backend.Context, targets: ^RenderTargets) {
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

// Resizes the targets to the swapchain's extent, then repoints every descriptor at them.
// The backend has already recreated the swapchain. Waits for idle: the bindless slots the new
// targets reuse may still be read by a frame in flight.
render_targets_resize :: proc(engine: ^Engine) {
	backend.device_wait_idle(&engine.vk_ctx)
	render_targets_destroy(&engine.vk_ctx, &engine.render_targets)
	engine.render_targets = render_targets_create(&engine.vk_ctx, engine.swapchain.extent)
	post_targets_update(engine)
}

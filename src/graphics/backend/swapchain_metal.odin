#+build darwin

package backend

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

RenderTargets :: struct {
	color: GpuImage,
	depth: GpuImage,
	draw:  GpuImage,
	bloom: GpuImage,
}

Swapchain :: struct {
	extent:           MTL.Size,
	render_targets:   RenderTargets,
	require_recreate: bool,
	current_drawable: ^CA.MetalDrawable,
}

swapchain_create :: proc(ctx: ^Context, width, height: u32) -> Swapchain {
	swapchain: Swapchain
	swapchain.extent = {NS.Integer(width), NS.Integer(height), 1}
	ctx.layer->setDrawableSize(NS.Size{NS.Float(width), NS.Float(height)})
	return swapchain
}

swapchain_destroy :: proc(ctx: ^Context, swapchain: ^Swapchain) {
	render_targets_destroy(ctx, &swapchain.render_targets)
}

render_target_create :: proc(
	ctx: ^Context,
	extent: MTL.Size,
	format: MTL.PixelFormat,
	usage: ImageUsageFlags,
	samples: u32 = 1,
) -> GpuImage {
	desc := image_desc_default(extent, format, usage)
	desc.samples = samples
	return image_create(ctx, desc)
}

render_targets_create :: proc(ctx: ^Context, extent: MTL.Size, msaa: u32) -> RenderTargets {
	return RenderTargets {
		color = render_target_create(ctx, extent, DRAW_FORMAT, {.Transient, .ColorAttachment}, samples = msaa),
		depth = render_target_create(ctx, extent, DEPTH_FORMAT, {.DepthStencilAttachment}, samples = msaa),
		draw = render_target_create(
			ctx,
			extent,
			DRAW_FORMAT,
			{.ColorAttachment, .TransferSrc, .TransferDst, .Storage},
		),
	}
}

render_targets_destroy :: proc(ctx: ^Context, targets: ^RenderTargets) {
	image_destroy(ctx, targets.color)
	image_destroy(ctx, targets.depth)
	image_destroy(ctx, targets.draw)
}

swapchain_acquire_next_image :: proc(
	ctx: ^Context,
	swapchain: ^Swapchain,
	frame_sync: ^FrameSync,
) -> AcquireImageResult {
	// The layer hands back nil whenever its drawable pool is momentarily empty --
	// occluded window, display asleep, or all drawables still in flight. None of that
	// invalidates our render targets, so this must not be reported as OutOfDate: the
	// caller would tear them down and rebuild them every frame for as long as it lasts.
	drawable := ctx.layer->nextDrawable()
	swapchain.current_drawable = drawable
	if drawable == nil {
		return .NotReady
	}
	return .Success
}

present_blit :: proc(ctx: ^Context, cmd: CommandBuffer, swapchain: ^Swapchain) {
	cmd_buffer := (^MTL.CommandBuffer)(cmd)
	encoder := cmd_buffer->blitCommandEncoder()
	encoder->copyFromTexture(swapchain.render_targets.draw.texture, swapchain.current_drawable->texture())
	encoder->endEncoding()
}

queue_present_frame :: proc(
	ctx: ^Context,
	cmd: CommandBuffer,
	swapchain: ^Swapchain,
	frame_sync: ^FrameSync,
) -> PresentFrameResult {
	cmd_buffer := (^MTL.CommandBuffer)(cmd)
	cmd_buffer->presentDrawable(swapchain.current_drawable)
	cmd_buffer->commit()
	return .Success
}

package backend

import vk "vendor:vulkan"

AttachmentInfo :: struct {
	image: Image, // zero handle = no attachment
	layer: u32,
	mip:   u32,
}

PassConfig :: struct {
	color:                 AttachmentInfo,
	resolve:               AttachmentInfo, // no image = no MSAA resolve
	depth:                 AttachmentInfo, // no image = no depth attachment
	clear_color:           [4]f32,
	load_op:               LoadOp,
	store_depth:           bool,
	skip_depth_transition: bool, // caller manages depth layout transitions
}

begin_render_pass :: proc(ctx: ^Context, cmd: CommandBuffer, config: PassConfig) -> RenderEncoder {
	if image_is_valid(config.color.image) {
		image_barrier(
			cmd,
			config.color.image,
			.Color_Write,
			ImageAspectFlags{.Color},
			base_array_layer = config.color.layer,
		)
	}

	if image_is_valid(config.resolve.image) && config.load_op != .Load {
		image_barrier(
			cmd,
			config.resolve.image,
			.Color_Write,
			ImageAspectFlags{.Color},
			base_array_layer = config.resolve.layer,
		)
	}

	if image_is_valid(config.depth.image) && !config.skip_depth_transition {
		image_barrier(
			cmd,
			config.depth.image,
			.Depth_Write,
			ImageAspectFlags{.Depth},
			base_array_layer = config.depth.layer,
		)
	}

	color_attach_info: vk.RenderingAttachmentInfo
	if image_is_valid(config.color.image) {
		color_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = image_attachment_view(
				image_slot(ctx, config.color.image),
				config.color.layer,
				config.color.mip,
			),
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = load_op_to_vk(config.load_op),
			storeOp = .DONT_CARE,
			clearValue = {color = {float32 = config.clear_color}},
		}
		if image_is_valid(config.resolve.image) {
			color_attach_info.resolveMode = {.AVERAGE}
			color_attach_info.resolveImageView = image_attachment_view(
				image_slot(ctx, config.resolve.image),
				config.resolve.layer,
				config.resolve.mip,
			)
			color_attach_info.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
		} else {
			color_attach_info.storeOp = .STORE
		}
	}

	extent: vk.Extent2D
	if image_is_valid(config.color.image) {
		e := image_slot(ctx, config.color.image).desc.extent
		extent = {e.width, e.height}
	} else if image_is_valid(config.depth.image) {
		e := image_slot(ctx, config.depth.image).desc.extent
		extent = {e.width, e.height}
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = extent},
		layerCount = 1,
		colorAttachmentCount = 1 if image_is_valid(config.color.image) else 0,
		pColorAttachments = &color_attach_info if image_is_valid(config.color.image) else nil,
	}

	depth_attach_info: vk.RenderingAttachmentInfo
	if image_is_valid(config.depth.image) {
		depth_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = image_attachment_view(
				image_slot(ctx, config.depth.image),
				config.depth.layer,
				config.depth.mip,
			),
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = load_op_to_vk(config.load_op),
			storeOp = .STORE if config.store_depth else .DONT_CARE,
			clearValue = {depthStencil = {depth = 1}},
		}
		rendering_info.pDepthAttachment = &depth_attach_info
	}

	vk.CmdBeginRendering(cmd.handle, &rendering_info)

	encoder := RenderEncoder(cmd)
	pipeline_set_viewport(encoder, f32(extent.width), f32(extent.height))
	pipeline_set_scissor(encoder, extent.width, extent.height)
	return encoder
}

end_render_pass :: proc(encoder: RenderEncoder) {
	vk.CmdEndRendering(encoder.handle)
}

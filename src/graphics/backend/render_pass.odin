package backend

import vk "vendor:vulkan"

AttachmentInfo :: struct {
	image: Image, // zero handle = no attachment
	layer: u32,
	mip:   u32,
}

PassConfig :: struct {
	color:       AttachmentInfo,
	resolve:     AttachmentInfo, // no image = no MSAA resolve
	depth:       AttachmentInfo, // no image = no depth attachment
	clear_color: [4]f32,
	load_op:     LoadOp,
	store_depth: bool,
}

// Attachments must already be in their attachment states; the pass executor owns frame-resource layouts.
begin_render_pass :: proc(cmd: CommandBuffer, config: PassConfig) -> RenderEncoder {
	color_attach_info: vk.RenderingAttachmentInfo
	if config.color.image != {} {
		color_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = image_attachment_view(
				image_slot(cmd.ctx, config.color.image),
				config.color.layer,
				config.color.mip,
			),
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = load_op_to_vk(config.load_op),
			storeOp = .DONT_CARE,
			clearValue = {color = {float32 = config.clear_color}},
		}
		if config.resolve.image != {} {
			color_attach_info.resolveMode = {.AVERAGE}
			color_attach_info.resolveImageView = image_attachment_view(
				image_slot(cmd.ctx, config.resolve.image),
				config.resolve.layer,
				config.resolve.mip,
			)
			color_attach_info.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
		} else {
			color_attach_info.storeOp = .STORE
		}
	}

	extent: vk.Extent2D
	if config.color.image != {} {
		e := image_slot(cmd.ctx, config.color.image).desc.extent
		extent = {e.width, e.height}
	} else if config.depth.image != {} {
		e := image_slot(cmd.ctx, config.depth.image).desc.extent
		extent = {e.width, e.height}
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = extent},
		layerCount = 1,
		colorAttachmentCount = 1 if config.color.image != {} else 0,
		pColorAttachments = &color_attach_info if config.color.image != {} else nil,
	}

	depth_attach_info: vk.RenderingAttachmentInfo
	if config.depth.image != {} {
		depth_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = image_attachment_view(
				image_slot(cmd.ctx, config.depth.image),
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

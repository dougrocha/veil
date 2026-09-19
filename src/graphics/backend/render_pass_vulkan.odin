#+build linux

package backend

import vk "vendor:vulkan"

AttachmentInfo :: struct {
	image: ^GpuImage, // nil = no attachment
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
	if config.color.image != nil {
		image_barrier(
			cmd,
			config.color.image,
			.Color_Write,
			ImageAspectFlags{.Color},
			base_array_layer = config.color.layer,
		)
	}

	if config.resolve.image != nil && config.load_op != .Load {
		image_barrier(
			cmd,
			config.resolve.image,
			.Color_Write,
			ImageAspectFlags{.Color},
			base_array_layer = config.resolve.layer,
		)
	}

	if config.depth.image != nil && !config.skip_depth_transition {
		image_barrier(
			cmd,
			config.depth.image,
			.Depth_Write,
			ImageAspectFlags{.Depth},
			base_array_layer = config.depth.layer,
		)
	}

	color_attach_info: vk.RenderingAttachmentInfo
	if config.color.image != nil {
		color_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = image_attachment_view(config.color.image, config.color.layer, config.color.mip),
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = load_op_to_vk(config.load_op),
			storeOp = .DONT_CARE,
			clearValue = {color = {float32 = config.clear_color}},
		}
		if config.resolve.image != nil {
			color_attach_info.resolveMode = {.AVERAGE}
			color_attach_info.resolveImageView = image_attachment_view(
				config.resolve.image,
				config.resolve.layer,
				config.resolve.mip,
			)
			color_attach_info.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
		} else {
			color_attach_info.storeOp = .STORE
		}
	}

	extent: vk.Extent2D
	if config.color.image != nil {
		extent = {config.color.image.extent.width, config.color.image.extent.height}
	} else if config.depth.image != nil {
		extent = {config.depth.image.extent.width, config.depth.image.extent.height}
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = extent},
		layerCount = 1,
		colorAttachmentCount = 1 if config.color.image != nil else 0,
		pColorAttachments = &color_attach_info if config.color.image != nil else nil,
	}

	depth_attach_info: vk.RenderingAttachmentInfo
	if config.depth.image != nil {
		depth_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = image_attachment_view(config.depth.image, config.depth.layer, config.depth.mip),
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = load_op_to_vk(config.load_op),
			storeOp = .STORE if config.store_depth else .DONT_CARE,
			clearValue = {depthStencil = {depth = 1}},
		}
		rendering_info.pDepthAttachment = &depth_attach_info
	}

	vk.CmdBeginRendering(vk.CommandBuffer(cmd), &rendering_info)

	encoder := RenderEncoder(cmd)
	pipeline_set_viewport(encoder, f32(extent.width), f32(extent.height))
	pipeline_set_scissor(encoder, extent.width, extent.height)
	return encoder
}

end_render_pass :: proc(encoder: RenderEncoder) {
	vk.CmdEndRendering(vk.CommandBuffer(encoder))
}

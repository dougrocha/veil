package graphics

import "backend"

import vk "vendor:vulkan"

AttachmentInfo :: struct {
	image: ^backend.GpuImage, // nil = no attachment
	layer: u32,
	mip:   u32,
}

PassConfig :: struct {
	color:                 AttachmentInfo,
	resolve:               AttachmentInfo, // no image = no MSAA resolve
	depth:                 AttachmentInfo, // no image = no depth attachment
	clear_color:           [4]f32,
	load_op:               backend.LoadOp,
	store_depth:           bool,
	skip_depth_transition: bool, // caller manages depth layout transitions
}

begin_render_pass :: proc(engine: ^Engine, cmd: backend.CommandBuffer, config: PassConfig) {
	if config.color.image != nil {
		from: backend.ImageStateKind = .Color_Write if config.load_op == .Load else .Undefined
		backend.image_barrier(cmd, config.color.image.image, from, .Color_Write, {.COLOR})
	}

	if config.resolve.image != nil && config.load_op != .Load {
		backend.image_barrier(cmd, config.resolve.image.image, .Undefined, .Color_Write, {.COLOR})
	}

	if config.depth.image != nil && !config.skip_depth_transition {
		from: backend.ImageStateKind = .Depth_Write if config.load_op == .Load else .Undefined
		backend.image_barrier(cmd, config.depth.image.image, from, .Depth_Write, {.DEPTH})
	}

	color_attach_info: vk.RenderingAttachmentInfo
	if config.color.image != nil {
		color_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = backend.image_attachment_view(config.color.image, config.color.layer, config.color.mip),
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = backend.load_op_to_vk(config.load_op),
			storeOp = .DONT_CARE,
			clearValue = {color = {float32 = config.clear_color}},
		}
		if config.resolve.image != nil {
			color_attach_info.resolveMode = {.AVERAGE}
			color_attach_info.resolveImageView = backend.image_attachment_view(
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
		extent = engine.swapchain.extent
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
			imageView = backend.image_attachment_view(config.depth.image, config.depth.layer, config.depth.mip),
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = backend.load_op_to_vk(config.load_op),
			storeOp = .STORE if config.store_depth else .DONT_CARE,
			clearValue = {depthStencil = {depth = 1}},
		}
		rendering_info.pDepthAttachment = &depth_attach_info
	}

	vk.CmdBeginRendering(vk.CommandBuffer(cmd), &rendering_info)

	backend.pipeline_set_viewport(cmd, f32(extent.width), f32(extent.height))
	backend.pipeline_set_scissor(cmd, extent.width, extent.height)
}

end_render_pass :: proc(cmd: backend.CommandBuffer) {
	vk.CmdEndRendering(vk.CommandBuffer(cmd))
}

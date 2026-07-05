package graphics

import "backend"

import vk "vendor:vulkan"

PassConfig :: struct {
	color_target:          ^GpuImage,
	resolve_target:        ^GpuImage, // nil = no MSAA resolve
	depth_target:          ^GpuImage, // nil = no depth attachment
	depth_view:            vk.ImageView, // overrides depth_target.image_view when set
	clear_color:           [4]f32,
	load_op:               vk.AttachmentLoadOp,
	store_depth:           bool,
	skip_depth_transition: bool, // caller manages depth layout transitions
}

begin_render_pass :: proc(engine: ^Engine, cmd: vk.CommandBuffer, config: PassConfig) {
	if config.color_target != nil {
		from: backend.ImageStateKind = .Color_Write if config.load_op == .LOAD else .Undefined
		backend.image_barrier(cmd, config.color_target.image, from, .Color_Write, {.COLOR})
	}

	if config.resolve_target != nil && config.load_op != .LOAD {
		backend.image_barrier(cmd, config.resolve_target.image, .Undefined, .Color_Write, {.COLOR})
	}

	if config.depth_target != nil && !config.skip_depth_transition {
		from: backend.ImageStateKind = .Depth_Write if config.load_op == .LOAD else .Undefined
		backend.image_barrier(cmd, config.depth_target.image, from, .Depth_Write, {.DEPTH})
	}

	color_attach_info: vk.RenderingAttachmentInfo
	if config.color_target != nil {
		color_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = config.color_target.image_view,
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = config.load_op,
			storeOp = .DONT_CARE,
			clearValue = {color = {float32 = config.clear_color}},
		}
		if config.resolve_target != nil {
			color_attach_info.resolveMode = {.AVERAGE}
			color_attach_info.resolveImageView = config.resolve_target.image_view
			color_attach_info.resolveImageLayout = .COLOR_ATTACHMENT_OPTIMAL
		} else {
			color_attach_info.storeOp = .STORE
		}
	}

	extent: vk.Extent2D
	if config.color_target != nil {
		extent = engine.swapchain.extent
	} else if config.depth_target != nil {
		extent = {config.depth_target.extent.width, config.depth_target.extent.height}
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = extent},
		layerCount = 1,
		colorAttachmentCount = 1 if config.color_target != nil else 0,
		pColorAttachments = &color_attach_info if config.color_target != nil else nil,
	}

	depth_attach_info: vk.RenderingAttachmentInfo
	if config.depth_target != nil {
		depth_view := config.depth_view if config.depth_view != 0 else config.depth_target.image_view
		depth_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = depth_view,
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = config.load_op,
			storeOp = .STORE if config.store_depth else .DONT_CARE,
			clearValue = {depthStencil = {depth = 1}},
		}
		rendering_info.pDepthAttachment = &depth_attach_info
	}

	vk.CmdBeginRendering(cmd, &rendering_info)

	backend.pipeline_set_viewport(cmd, f32(extent.width), f32(extent.height))
	backend.pipeline_set_scissor(cmd, extent.width, extent.height)
}

end_render_pass :: proc(cmd: vk.CommandBuffer) {
	vk.CmdEndRendering(cmd)
}

package graphics

import vk "vendor:vulkan"

PassConfig :: struct {
	color_target:   ^GpuImage,
	resolve_target: ^GpuImage, // nil = no MSAA resolve
	depth_target:   ^GpuImage, // nil = no depth attachment
	clear_color:    [4]f32,
	load_op:        vk.AttachmentLoadOp,
}

begin_render_pass :: proc(engine: ^Engine, cmd: vk.CommandBuffer, config: PassConfig) {
	if config.color_target != nil {
		src_layout: vk.ImageLayout = .COLOR_ATTACHMENT_OPTIMAL if config.load_op == .LOAD else .UNDEFINED
		transition_image_layout(
			cmd,
			config.color_target.image,
			src_layout,
			.COLOR_ATTACHMENT_OPTIMAL,
			{.COLOR_ATTACHMENT_WRITE} if config.load_op == .LOAD else {},
			{.COLOR_ATTACHMENT_WRITE},
			{.COLOR_ATTACHMENT_OUTPUT},
			{.COLOR_ATTACHMENT_OUTPUT},
			{.COLOR},
		)
	}

	if config.resolve_target != nil && config.load_op != .LOAD {
		transition_image_layout(
			cmd,
			config.resolve_target.image,
			.UNDEFINED,
			.COLOR_ATTACHMENT_OPTIMAL,
			{},
			{.COLOR_ATTACHMENT_WRITE},
			{.COLOR_ATTACHMENT_OUTPUT},
			{.COLOR_ATTACHMENT_OUTPUT},
			{.COLOR},
		)
	}

	if config.depth_target != nil {
		transition_image_layout(
			cmd,
			config.depth_target.image,
			.UNDEFINED,
			.DEPTH_ATTACHMENT_OPTIMAL,
			{},
			{.DEPTH_STENCIL_ATTACHMENT_WRITE},
			{.EARLY_FRAGMENT_TESTS},
			{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			{.DEPTH},
		)
	}

	color_attach_info := vk.RenderingAttachmentInfo {
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

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {offset = {0, 0}, extent = engine.swapchain.extent},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attach_info,
	}

	depth_attach_info: vk.RenderingAttachmentInfo
	if config.depth_target != nil {
		depth_attach_info = vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = config.depth_target.image_view,
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = config.load_op,
			storeOp = .DONT_CARE,
			clearValue = {depthStencil = {depth = 1}},
		}
		rendering_info.pDepthAttachment = &depth_attach_info
	}

	vk.CmdBeginRendering(cmd, &rendering_info)

	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(engine.swapchain.extent.width),
		height   = f32(engine.swapchain.extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {x = 0, y = 0},
		extent = engine.swapchain.extent,
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)

}

end_render_pass :: proc(cmd: vk.CommandBuffer) {
	vk.CmdEndRendering(cmd)
}

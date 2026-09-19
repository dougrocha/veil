#+build darwin

package backend

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

AttachmentInfo :: struct {
	image: ^GpuImage,
	layer: u32,
	mip:   u32,
}

PassConfig :: struct {
	color:                 AttachmentInfo,
	resolve:               AttachmentInfo,
	depth:                 AttachmentInfo,
	clear_color:           [4]f32,
	load_op:               LoadOp,
	store_depth:           bool,
	skip_depth_transition: bool,
}

begin_render_pass :: proc(ctx: ^Context, cmd: CommandBuffer, config: PassConfig) -> RenderEncoder {
	cmd_buffer := (^MTL.CommandBuffer)(cmd)
	pass_desc := MTL.RenderPassDescriptor.renderPassDescriptor()

	if config.color.image != nil {
		attachment := pass_desc->colorAttachments()->object(0)
		attachment->setTexture(config.color.image.texture)
		attachment->setLevel(NS.UInteger(config.color.mip))
		attachment->setSlice(NS.UInteger(config.color.layer))
		attachment->setLoadAction(load_op_to_mtl(config.load_op))
		attachment->setClearColor(
			MTL.ClearColor {
				f64(config.clear_color.x),
				f64(config.clear_color.y),
				f64(config.clear_color.z),
				f64(config.clear_color.w),
			},
		)

		if config.resolve.image != nil {
			attachment->setResolveTexture(config.resolve.image.texture)
			attachment->setResolveLevel(NS.UInteger(config.resolve.mip))
			attachment->setResolveSlice(NS.UInteger(config.resolve.layer))
			attachment->setStoreAction(.MultisampleResolve)
		} else {
			attachment->setStoreAction(.Store)
		}
	}

	if config.depth.image != nil {
		attachment := pass_desc->depthAttachment()
		attachment->setTexture(config.depth.image.texture)
		attachment->setLevel(NS.UInteger(config.depth.mip))
		attachment->setSlice(NS.UInteger(config.depth.layer))
		attachment->setLoadAction(load_op_to_mtl(config.load_op))
		attachment->setStoreAction(.Store if config.store_depth else .DontCare)
		attachment->setClearDepth(1)
	}

	encoder := RenderEncoder(cmd_buffer->renderCommandEncoderWithDescriptor(pass_desc))
	extent := config.color.image.extent if config.color.image != nil else config.depth.image.extent
	pipeline_set_viewport(encoder, f32(extent.width), f32(extent.height))
	pipeline_set_scissor(encoder, u32(extent.width), u32(extent.height))
	return encoder
}

end_render_pass :: proc(encoder: RenderEncoder) {
	(^MTL.RenderCommandEncoder)(encoder)->endEncoding()
}

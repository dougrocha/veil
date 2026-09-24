#+build darwin

package backend

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

Pipeline :: struct {
	render_state:        ^MTL.RenderPipelineState,
	compute_state:       ^MTL.ComputePipelineState,
	depth_stencil_write: ^MTL.DepthStencilState,
	depth_stencil_read:  ^MTL.DepthStencilState,
	depth_write_default: bool,
	depth_clamp:         bool,
	primitive_type:      MTL.PrimitiveType,
}

pipeline_bind :: proc(cmd: RenderEncoder, pipeline: Pipeline, desc_sets: []DescriptorSetHandle = {}) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	encoder->setRenderPipelineState(pipeline.render_state)
	encoder->setDepthStencilState(
		pipeline.depth_stencil_write if pipeline.depth_write_default else pipeline.depth_stencil_read,
	)
	// Encoder state, not pipeline state: set it on every bind so it can't leak between pipelines.
	encoder->setDepthClipMode(.Clamp if pipeline.depth_clamp else .Clip)
	for set, i in desc_sets {
		if set.bindless {
			encoder->setVertexBuffer(set.buffer, 0, 0)
			encoder->setFragmentBuffer(set.buffer, 0, 0)
			for texture in set.textures {
				if texture != nil {
					encoder->useResourceWithStages((^MTL.Resource)(texture), {.Read, .Sample}, {.Fragment})
				}
			}
		} else {
			for texture, binding in set.textures {
				if texture != nil do encoder->setFragmentTexture(texture, NS.UInteger(binding))
			}
			for sampler, binding in set.samplers {
				if sampler != nil do encoder->setFragmentSamplerState(sampler, NS.UInteger(binding))
			}
		}
	}
}

pipeline_push :: proc(
	cmd: RenderEncoder,
	pipeline: Pipeline,
	stages: bit_set[ShaderStage],
	data: ^$T,
	index: u32 = 0,
) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	bytes := (cast([^]byte)data)[:size_of(T)]
	if .Vertex in stages {
		encoder->setVertexBytes(bytes, NS.UInteger(index))
	}
	if .Fragment in stages {
		encoder->setFragmentBytes(bytes, NS.UInteger(index))
	}
}

pipeline_set_viewport :: proc(cmd: RenderEncoder, width: f32, height: f32, offset_x: f32 = 0, offset_y: f32 = 0) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	encoder->setViewport(MTL.Viewport{f64(offset_x), f64(offset_y), f64(width), f64(height), 0, 1})
}

pipeline_set_scissor :: proc(cmd: RenderEncoder, width: u32, height: u32, offset_x: i32 = 0, offset_y: i32 = 0) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	encoder->setScissorRect(
		MTL.ScissorRect{NS.Integer(offset_x), NS.Integer(offset_y), NS.Integer(width), NS.Integer(height)},
	)
}

pipeline_set_depth_write :: proc(cmd: RenderEncoder, pipeline: Pipeline, enabled: bool) {
	encoder := (^MTL.RenderCommandEncoder)(cmd)
	encoder->setDepthStencilState(pipeline.depth_stencil_write if enabled else pipeline.depth_stencil_read)
}

BlendModeAttachment :: enum {
	Alpha,
	Additive,
}

GraphicsPipelineConfig :: struct {
	cull_mode:            MTL.CullMode,
	front_face:           MTL.Winding,
	fill_mode:            MTL.TriangleFillMode,
	sample_count:         u32,
	color_format:         MTL.PixelFormat,
	depth_format:         MTL.PixelFormat,
	blend_enabled:        bool,
	rgb_blend_op:         MTL.BlendOperation,
	src_rgb_blend_factor: MTL.BlendFactor,
	dst_rgb_blend_factor: MTL.BlendFactor,
	depth_compare:        CompareOp,
	depth_test_enabled:   bool,
	depth_write_default:  bool,
	depth_bias_enabled:   bool,
	depth_clamp:          bool,
	has_color_attachment: bool,
	has_depth_attachment: bool,
	primitive_type:       MTL.PrimitiveType,
}

ComputePipelineConfig :: struct {}

PipelineConfig :: union {
	GraphicsPipelineConfig,
	ComputePipelineConfig,
}

pipeline_default_config :: proc() -> (config: GraphicsPipelineConfig) {
	config.cull_mode = .Back
	config.front_face = .CounterClockwise
	config.fill_mode = .Fill
	config.sample_count = 1
	config.color_format = DRAW_FORMAT
	config.depth_format = DEPTH_FORMAT
	config.depth_compare = .Less
	config.depth_test_enabled = true
	config.depth_write_default = true
	config.has_color_attachment = true
	config.has_depth_attachment = true
	config.primitive_type = .Triangle
	config.src_rgb_blend_factor = .One
	config.dst_rgb_blend_factor = .Zero
	config.rgb_blend_op = .Add
	return
}

pipeline_config_set_no_cull :: proc(config: ^GraphicsPipelineConfig) {
	config.cull_mode = .None
}

pipeline_config_enable_depth_bias :: proc(config: ^GraphicsPipelineConfig) {
	config.depth_bias_enabled = true
}

// Rasterizes geometry beyond the near/far planes with its depth clamped to the depth range
// instead of clipping it (used to "pancake" directional shadow casters onto the near plane).
pipeline_config_enable_depth_clamp :: proc(config: ^GraphicsPipelineConfig) {
	config.depth_clamp = true
}

pipeline_config_set_depth_compare :: proc(config: ^GraphicsPipelineConfig, op: CompareOp) {
	config.depth_compare = op
}

pipeline_config_set_depth_write_default :: proc(config: ^GraphicsPipelineConfig, enabled: bool) {
	config.depth_write_default = enabled
}

pipeline_config_set_depth_dynamic :: proc(config: ^GraphicsPipelineConfig) {
}

pipeline_config_disable_color_attachment :: proc(config: ^GraphicsPipelineConfig) {
	config.has_color_attachment = false
}

pipeline_config_set_no_depth_attachment :: proc(config: ^GraphicsPipelineConfig) {
	config.has_depth_attachment = false
}

pipeline_config_set_topology_points :: proc(config: ^GraphicsPipelineConfig) {
	config.primitive_type = .Point
}

pipeline_config_set_msaa :: proc(config: ^GraphicsPipelineConfig, ctx: ^Context) {
	config.sample_count = ctx.msaa_samples
}

pipeline_config_set_descriptor_layouts :: proc(config: ^GraphicsPipelineConfig, sets: ..DescriptorSet) {
}

pipeline_config_set_push_constant :: proc(config: ^GraphicsPipelineConfig, size: int, stages: bit_set[ShaderStage]) {
}

pipeline_config_set_push_constant_compute :: proc(
	config: ^ComputePipelineConfig,
	size: int,
	stages: bit_set[ShaderStage],
) {
}

compare_op_to_mtl :: proc(op: CompareOp) -> MTL.CompareFunction {
	switch op {
	case .Never:
		return .Never
	case .Less:
		return .Less
	case .Equal:
		return .Equal
	case .LessOrEqual:
		return .LessEqual
	case .Greater:
		return .Greater
	case .NotEqual:
		return .NotEqual
	case .GreaterOrEqual:
		return .GreaterEqual
	case .Always:
		return .Always
	}
	return .Less
}

pipeline_config_set_blend :: proc(config: ^GraphicsPipelineConfig, mode: BlendModeAttachment) {
	config.blend_enabled = true
	config.rgb_blend_op = .Add
	switch mode {
	case .Alpha:
		config.src_rgb_blend_factor = .SourceAlpha
		config.dst_rgb_blend_factor = .OneMinusSourceAlpha
	case .Additive:
		config.src_rgb_blend_factor = .SourceAlpha
		config.dst_rgb_blend_factor = .One
	}
}

pipeline_config_disable_depth :: proc(config: ^GraphicsPipelineConfig) {
	config.depth_test_enabled = false
	config.depth_write_default = false
}

pipeline_create :: proc(ctx: ^Context, config: ^GraphicsPipelineConfig, stages: []ShaderStageDesc) -> Pipeline {
	desc := MTL.RenderPipelineDescriptor.alloc()->init()
	defer desc->release()

	for stage in stages {
		fn := shader_stage_function(stage)
		defer fn->release()
		if stage.stage == .Vertex {
			desc->setVertexFunction(fn)
		} else if stage.stage == .Fragment {
			desc->setFragmentFunction(fn)
		}
	}

	if config.has_color_attachment {
		color_attachment := desc->colorAttachments()->object(0)
		color_attachment->setPixelFormat(config.color_format)
		color_attachment->setBlendingEnabled(config.blend_enabled)
		color_attachment->setRgbBlendOperation(config.rgb_blend_op)
		color_attachment->setSourceRGBBlendFactor(config.src_rgb_blend_factor)
		color_attachment->setDestinationRGBBlendFactor(config.dst_rgb_blend_factor)
		color_attachment->setAlphaBlendOperation(.Add)
		// Accumulate coverage rather than overwriting it: One/Zero would leave the
		// target transparent everywhere a blended pass drew.
		color_attachment->setSourceAlphaBlendFactor(.One)
		color_attachment->setDestinationAlphaBlendFactor(.OneMinusSourceAlpha)
	}

	if config.has_depth_attachment {
		desc->setDepthAttachmentPixelFormat(config.depth_format)
	}
	desc->setSampleCount(NS.UInteger(config.sample_count))

	render_state, err := ctx.device->newRenderPipelineStateWithDescriptor(desc)
	if err != nil {
		return {}
	}

	mtl_compare := compare_op_to_mtl(config.depth_compare) if config.depth_test_enabled else MTL.CompareFunction.Always

	depth_write_desc := MTL.DepthStencilDescriptor.alloc()->init()
	defer depth_write_desc->release()
	depth_write_desc->setDepthCompareFunction(mtl_compare)
	depth_write_desc->setDepthWriteEnabled(true)
	depth_stencil_write := ctx.device->newDepthStencilState(depth_write_desc)

	depth_read_desc := MTL.DepthStencilDescriptor.alloc()->init()
	defer depth_read_desc->release()
	depth_read_desc->setDepthCompareFunction(mtl_compare)
	depth_read_desc->setDepthWriteEnabled(false)
	depth_stencil_read := ctx.device->newDepthStencilState(depth_read_desc)

	return Pipeline {
		render_state = render_state,
		depth_stencil_write = depth_stencil_write,
		depth_stencil_read = depth_stencil_read,
		depth_write_default = config.depth_write_default,
		depth_clamp = config.depth_clamp,
		primitive_type = config.primitive_type,
	}
}

pipeline_create_compute :: proc(ctx: ^Context, config: ^ComputePipelineConfig, stage: ShaderStageDesc) -> Pipeline {
	fn := shader_stage_function(stage)
	compute_state, err := ctx.device->newComputePipelineState(fn)
	if err != nil {
		return {}
	}
	return Pipeline{compute_state = compute_state}
}

pipeline_destroy :: proc(ctx: ^Context, pipeline: Pipeline) {
	if pipeline.render_state != nil do pipeline.render_state->release()
	if pipeline.compute_state != nil do pipeline.compute_state->release()
	if pipeline.depth_stencil_write != nil do pipeline.depth_stencil_write->release()
	if pipeline.depth_stencil_read != nil do pipeline.depth_stencil_read->release()
}

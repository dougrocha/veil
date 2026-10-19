package backend

import vk "vendor:vulkan"

// Every pipeline shares one push constant block of this size, visible to every stage.
// 128 bytes is the minimum maxPushConstantsSize the spec guarantees.
PUSH_CONSTANT_SIZE :: 128

@(private)
PUSH_CONSTANT_STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT, .COMPUTE}

Pipeline :: struct {
	pipeline: vk.Pipeline,
}

MAX_COLOR_ATTACHMENTS :: 8

// What a graphics pipeline renders into. The owner of the images builds it from their formats,
// so a pipeline can't disagree with the pass it draws in. depth = .Undefined means no depth.
AttachmentLayout :: struct {
	color:       [MAX_COLOR_ATTACHMENTS]Format,
	color_count: u32,
	depth:       Format,
	samples:     u32,
}

// The zero value of every field is "off" or the common case.
Topology :: enum u8 {
	Triangles,
	Points,
	Lines,
}

CullMode :: enum u8 {
	Back,
	None,
	Front,
}

BlendMode :: enum u8 {
	None,
	Alpha,
	Additive,
}

// Zero value: no depth test, no depth write.
DepthState :: struct {
	test:    bool,
	write:   bool, // only takes effect with test
	bias:    bool, // values set per draw with cmd_set_depth_bias
	clamp:   bool, // clamp instead of clipping at near/far (pancakes directional shadow casters)
	compare: CompareOp,
}

GraphicsPipelineDesc :: struct {
	attachments: AttachmentLayout,
	topology:    Topology,
	cull:        CullMode,
	blend:       BlendMode,
	depth:       DepthState,
}

// Binds the pipeline and the bindless table (set 0).
pipeline_bind :: proc(cmd: RenderEncoder, pipeline: Pipeline) {
	vk.CmdBindPipeline(cmd.handle, .GRAPHICS, pipeline.pipeline)
	vk.CmdBindDescriptorSets(
		cmd.handle,
		.GRAPHICS,
		cmd.ctx.bindless.pipeline_layout,
		0,
		1,
		&cmd.ctx.bindless.set,
		0,
		nil,
	)
}

pipeline_push :: proc(cmd: RenderEncoder, data: ^$T) {
	#assert(size_of(T) <= PUSH_CONSTANT_SIZE)
	vk.CmdPushConstants(cmd.handle, cmd.ctx.bindless.pipeline_layout, PUSH_CONSTANT_STAGES, 0, u32(size_of(T)), data)
}

pipeline_set_viewport :: proc(cmd: RenderEncoder, width: f32, height: f32, offset_x: f32 = 0, offset_y: f32 = 0) {
	viewport := vk.Viewport {
		x        = offset_x,
		y        = offset_y,
		width    = width,
		height   = height,
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(cmd.handle, 0, 1, &viewport)
}

pipeline_set_scissor :: proc(cmd: RenderEncoder, width: u32, height: u32, offset_x: i32 = 0, offset_y: i32 = 0) {
	scissor := vk.Rect2D {
		offset = {offset_x, offset_y},
		extent = {width, height},
	}
	vk.CmdSetScissor(cmd.handle, 0, 1, &scissor)
}

pipeline_create :: proc(ctx: ^Context, desc: GraphicsPipelineDesc, stages: []ShaderStageDesc) -> Pipeline {
	attachments := desc.attachments
	depth := desc.depth
	assert(
		attachments.color_count > 0 || attachments.depth != .Undefined,
		"pipeline_create: desc has no attachment layout",
	)
	assert(attachments.samples > 0, "pipeline_create: attachment layout has no sample count")
	assert(!depth.test || attachments.depth != .Undefined, "pipeline_create: depth test without a depth attachment")
	assert(!depth.test || depth.compare != .Never, "pipeline_create: depth test with compare .Never draws nothing")
	assert(!depth.write || depth.test, "pipeline_create: depth write needs depth test")

	shader_stages := make([]vk.PipelineShaderStageCreateInfo, len(stages), context.temp_allocator)
	for stage_desc, i in stages {
		stage: ShaderStage
		shader_stages[i], stage = shader_stage_info(ctx, stage_desc)
		assert(stage != .Compute, "pipeline_create: compute entry point in a graphics pipeline")
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = topology_to_vk(desc.topology),
	}

	viewport := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterization := vk.PipelineRasterizationStateCreateInfo {
		sType            = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable = b32(depth.clamp),
		polygonMode      = .FILL,
		cullMode         = cull_mode_to_vk(desc.cull),
		frontFace        = .COUNTER_CLOCKWISE,
		depthBiasEnable  = b32(depth.bias),
		lineWidth        = 1.0,
	}

	multi_sample := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = samples_to_vk(attachments.samples),
		minSampleShading     = 1.0,
	}

	// Every color attachment shares the one blend state.
	blend_attachment := blend_mode_to_vk(desc.blend)
	blend_attachments: [MAX_COLOR_ATTACHMENTS]vk.PipelineColorBlendAttachmentState
	for i in 0 ..< attachments.color_count {
		blend_attachments[i] = blend_attachment
	}
	color_blend := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = attachments.color_count,
		pAttachments    = &blend_attachments[0],
	}

	depth_stencil := vk.PipelineDepthStencilStateCreateInfo {
		sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable  = b32(depth.test),
		depthWriteEnable = b32(depth.write),
		depthCompareOp   = compare_op_to_vk(depth.compare),
		maxDepthBounds   = 1,
	}

	// The backend decides what is dynamic: what Metal treats as encoder state.
	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR, .DEPTH_BIAS}
	dynamic_state := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = len(dynamic_states),
		pDynamicStates    = &dynamic_states[0],
	}

	color_formats: [MAX_COLOR_ATTACHMENTS]vk.Format
	for i in 0 ..< attachments.color_count {
		color_formats[i] = format_to_vk(attachments.color[i])
	}
	rendering_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = attachments.color_count,
		pColorAttachmentFormats = &color_formats[0],
		depthAttachmentFormat   = format_to_vk(attachments.depth),
	}

	info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport,
		pRasterizationState = &rasterization,
		pMultisampleState   = &multi_sample,
		pDepthStencilState  = &depth_stencil,
		pColorBlendState    = &color_blend,
		pDynamicState       = &dynamic_state,
		layout              = ctx.bindless.pipeline_layout,
	}

	pipeline: vk.Pipeline
	vk_check(vk.CreateGraphicsPipelines(ctx.device, 0, 1, &info, nil, &pipeline))
	return Pipeline{pipeline = pipeline}
}

pipeline_create_compute :: proc(ctx: ^Context, stage: ShaderStageDesc) -> Pipeline {
	stage_info, shader_stage := shader_stage_info(ctx, stage)
	assert(shader_stage == .Compute, "pipeline_create_compute: entry point is not a compute stage")
	info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		stage  = stage_info,
		layout = ctx.bindless.pipeline_layout,
	}

	pipeline: vk.Pipeline
	vk_check(vk.CreateComputePipelines(ctx.device, 0, 1, &info, nil, &pipeline))
	return Pipeline{pipeline = pipeline}
}

// Deferred like images and buffers: frames in flight may still be using it.
pipeline_destroy :: proc(ctx: ^Context, pipeline: Pipeline) {
	release_deferred(ctx, pipeline)
}

@(private)
compare_op_to_vk :: proc(op: CompareOp) -> vk.CompareOp {
	switch op {
	case .Never:
		return .NEVER
	case .Less:
		return .LESS
	case .Equal:
		return .EQUAL
	case .LessOrEqual:
		return .LESS_OR_EQUAL
	case .Greater:
		return .GREATER
	case .NotEqual:
		return .NOT_EQUAL
	case .GreaterOrEqual:
		return .GREATER_OR_EQUAL
	case .Always:
		return .ALWAYS
	}
	return .LESS
}

@(private = "file")
topology_to_vk :: proc(topology: Topology) -> vk.PrimitiveTopology {
	switch topology {
	case .Triangles:
		return .TRIANGLE_LIST
	case .Points:
		return .POINT_LIST
	case .Lines:
		return .LINE_LIST
	}
	return .TRIANGLE_LIST
}

@(private = "file")
cull_mode_to_vk :: proc(cull: CullMode) -> vk.CullModeFlags {
	switch cull {
	case .Back:
		return {.BACK}
	case .None:
		return {}
	case .Front:
		return {.FRONT}
	}
	return {.BACK}
}

@(private = "file")
blend_mode_to_vk :: proc(mode: BlendMode) -> vk.PipelineColorBlendAttachmentState {
	state := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = {.R, .G, .B, .A},
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ZERO,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
	}
	switch mode {
	case .None:
	case .Alpha:
		state.blendEnable = true
		state.srcColorBlendFactor = .SRC_ALPHA
		state.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
	case .Additive:
		state.blendEnable = true
		state.srcColorBlendFactor = .SRC_ALPHA
		state.dstColorBlendFactor = .ONE
	}
	return state
}

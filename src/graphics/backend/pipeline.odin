package backend

import vk "vendor:vulkan"

Pipeline :: struct {
	layout:   vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

pipeline_bind :: proc(cmd: CommandBuffer, pipeline: Pipeline, desc_sets: []vk.DescriptorSet = {}) {
	raw_cmd := cmd.handle
	vk.CmdBindPipeline(raw_cmd, .GRAPHICS, pipeline.pipeline)

	if len(desc_sets) > 0 {
		vk.CmdBindDescriptorSets(
			raw_cmd,
			.GRAPHICS,
			pipeline.layout,
			0,
			u32(len(desc_sets)),
			raw_data(desc_sets),
			0,
			nil,
		)
	}
}

pipeline_push :: proc(
	cmd: CommandBuffer,
	pipeline: Pipeline,
	stages: bit_set[ShaderStage],
	data: ^$T,
	index: u32 = 0,
) {
	vk.CmdPushConstants(cmd.handle, pipeline.layout, shader_stages_to_vk(stages), 0, u32(size_of(T)), data)
}

pipeline_set_viewport :: proc(cmd: CommandBuffer, width: f32, height: f32, offset_x: f32 = 0, offset_y: f32 = 0) {
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

pipeline_set_scissor :: proc(cmd: CommandBuffer, width: u32, height: u32, offset_x: i32 = 0, offset_y: i32 = 0) {
	scissor := vk.Rect2D {
		offset = {offset_x, offset_y},
		extent = {width, height},
	}
	vk.CmdSetScissor(cmd.handle, 0, 1, &scissor)
}

pipeline_set_depth_write :: proc(cmd: CommandBuffer, pipeline: Pipeline, enabled: bool) {
	vk.CmdSetDepthWriteEnable(cmd.handle, b32(enabled))
}

BlendModeAttachment :: enum {
	Alpha,
	Additive,
}

pipeline_config_set_blend :: proc(config: ^GraphicsPipelineConfig, mode: BlendModeAttachment) {
	config.color_blend_attachment.blendEnable = true
	config.color_blend_attachment.alphaBlendOp = .ADD
	config.color_blend_attachment.srcAlphaBlendFactor = .ONE
	config.color_blend_attachment.dstAlphaBlendFactor = .ZERO

	switch mode {
	case .Alpha:
		config.color_blend_attachment.colorBlendOp = .ADD
		config.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
		config.color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
	case .Additive:
		config.color_blend_attachment.colorBlendOp = .ADD
		config.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
		config.color_blend_attachment.dstColorBlendFactor = .ONE
	}
}

pipeline_config_disable_depth :: proc(config: ^GraphicsPipelineConfig) {
	config.depth_stencil.depthTestEnable = false
	config.depth_stencil.depthWriteEnable = false
}

pipeline_config_set_descriptor_layouts :: proc(config: ^GraphicsPipelineConfig, sets: ..DescriptorSet) {
	for set, i in sets {
		config.descriptor_layouts[i] = set.layout
	}
	config.descriptor_layout_count = u32(len(sets))
}

pipeline_config_set_descriptor_layouts_compute :: proc(config: ^ComputePipelineConfig, sets: ..DescriptorSet) {
	for set, i in sets {
		config.descriptor_layouts[i] = set.layout
	}
	config.descriptor_layout_count = u32(len(sets))
}

pipeline_config_set_no_cull :: proc(config: ^GraphicsPipelineConfig) {
	config.rasterization.cullMode = {}
}

pipeline_config_enable_depth_bias :: proc(config: ^GraphicsPipelineConfig) {
	config.rasterization.depthBiasEnable = true
}

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

// Rasterizes geometry beyond the near/far planes with its depth clamped to the depth range
// instead of clipping it (used to "pancake" directional shadow casters onto the near plane).
pipeline_config_enable_depth_clamp :: proc(config: ^GraphicsPipelineConfig) {
	config.rasterization.depthClampEnable = true
}

pipeline_config_set_depth_compare :: proc(config: ^GraphicsPipelineConfig, op: CompareOp) {
	config.depth_stencil.depthCompareOp = compare_op_to_vk(op)
}

pipeline_config_set_depth_write_default :: proc(config: ^GraphicsPipelineConfig, enabled: bool) {
	config.depth_stencil.depthWriteEnable = b32(enabled)
}

pipeline_config_set_depth_dynamic :: proc(config: ^GraphicsPipelineConfig) {
	config.dynamic_states[config.dynamic_state_count] = .DEPTH_WRITE_ENABLE
	config.dynamic_state_count += 1
}

pipeline_config_set_topology_points :: proc(config: ^GraphicsPipelineConfig) {
	config.input_assembly.topology = .POINT_LIST
}

shader_stages_to_vk :: proc(stages: bit_set[ShaderStage]) -> vk.ShaderStageFlags {
	flags: vk.ShaderStageFlags
	if .Vertex in stages do flags += {.VERTEX}
	if .Fragment in stages do flags += {.FRAGMENT}
	if .Compute in stages do flags += {.COMPUTE}
	return flags
}

pipeline_config_set_push_constant :: proc(config: ^GraphicsPipelineConfig, size: int, stages: bit_set[ShaderStage]) {
	config.push_constant_range = {
		stageFlags = shader_stages_to_vk(stages),
		size       = u32(size),
	}
}

pipeline_config_set_push_constant_compute :: proc(
	config: ^ComputePipelineConfig,
	size: int,
	stages: bit_set[ShaderStage],
) {
	config.push_constant_range = {
		stageFlags = shader_stages_to_vk(stages),
		size       = u32(size),
	}
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

pipeline_config_set_layout :: proc(config: ^GraphicsPipelineConfig, layout: AttachmentLayout) {
	config.attachments = layout
}

GraphicsPipelineConfig :: struct {
	viewport:                vk.PipelineViewportStateCreateInfo,
	input_assembly:          vk.PipelineInputAssemblyStateCreateInfo,
	rasterization:           vk.PipelineRasterizationStateCreateInfo,
	multi_sample:            vk.PipelineMultisampleStateCreateInfo,
	color_blend_attachment:  vk.PipelineColorBlendAttachmentState,
	color_blend:             vk.PipelineColorBlendStateCreateInfo,
	depth_stencil:           vk.PipelineDepthStencilStateCreateInfo,
	dynamic_states:          [4]vk.DynamicState,
	dynamic_state_count:     u32,
	attachments:             AttachmentLayout,
	descriptor_layouts:      [8]vk.DescriptorSetLayout,
	descriptor_layout_count: u32,
	push_constant_range:     vk.PushConstantRange,
}

ComputePipelineConfig :: struct {
	descriptor_layouts:      [8]vk.DescriptorSetLayout,
	descriptor_layout_count: u32,
	push_constant_range:     vk.PushConstantRange,
}

PipelineConfig :: union {
	GraphicsPipelineConfig,
	ComputePipelineConfig,
}

pipeline_default_config :: proc() -> (config: GraphicsPipelineConfig) {
	config.viewport = {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		pViewports    = nil,
		viewportCount = 1,
		pScissors     = nil,
		scissorCount  = 1,
	}

	config.input_assembly = {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	config.rasterization = {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		cullMode                = {.BACK},
		frontFace               = .COUNTER_CLOCKWISE,
		depthBiasEnable         = false,
		depthBiasConstantFactor = 0,
		depthBiasClamp          = 0,
		depthBiasSlopeFactor    = 0,
		lineWidth               = 1.0,
	}

	config.dynamic_states[0] = .VIEWPORT
	config.dynamic_states[1] = .SCISSOR
	config.dynamic_states[2] = .DEPTH_BIAS
	config.dynamic_state_count = 3

	config.multi_sample = {
		sType                 = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable   = false,
		rasterizationSamples  = {._1},
		minSampleShading      = 1.0,
		alphaToCoverageEnable = false,
		alphaToOneEnable      = false,
	}

	config.color_blend_attachment = {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = false,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ZERO,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
	}

	config.color_blend = {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		blendConstants  = {0, 0, 0, 0},
	}

	config.depth_stencil = {
		sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable       = true,
		depthWriteEnable      = true,
		depthCompareOp        = .LESS,
		depthBoundsTestEnable = false,
		minDepthBounds        = 0,
		maxDepthBounds        = 1,
		stencilTestEnable     = false,
		front                 = {},
		back                  = {},
	}
	return
}

pipeline_create :: proc(ctx: ^Context, config: ^GraphicsPipelineConfig, stages: []ShaderStageDesc) -> Pipeline {
	device := ctx.device
	attachments := &config.attachments
	assert(
		attachments.color_count > 0 || attachments.depth != .Undefined,
		"pipeline_create: no attachment layout set (pipeline_config_set_layout)",
	)
	assert(attachments.samples > 0, "pipeline_create: attachment layout has no sample count")
	layout_info := pipeline_build_layout_info(
		&config.descriptor_layouts,
		config.descriptor_layout_count,
		&config.push_constant_range,
	)

	layout: vk.PipelineLayout
	vk_check(vk.CreatePipelineLayout(device, &layout_info, nil, &layout))

	shader_stages := make([]vk.PipelineShaderStageCreateInfo, len(stages), context.temp_allocator)
	for desc, i in stages {
		shader_stages[i] = shader_stage_info(desc)
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = config.dynamic_state_count,
		pDynamicStates    = raw_data(&config.dynamic_states),
	}

	// Every color attachment shares the one blend state.
	blend_attachments: [MAX_COLOR_ATTACHMENTS]vk.PipelineColorBlendAttachmentState
	for i in 0 ..< attachments.color_count {
		blend_attachments[i] = config.color_blend_attachment
	}
	color_blend := config.color_blend
	color_blend.attachmentCount = attachments.color_count
	color_blend.pAttachments = &blend_attachments[0]

	multi_sample := config.multi_sample
	multi_sample.rasterizationSamples = samples_to_vk(attachments.samples)

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

	graphics_pipeline := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rendering_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &config.input_assembly,
		// pTessellationState:  ^PipelineTessellationStateCreateInfo,
		pViewportState      = &config.viewport,
		pRasterizationState = &config.rasterization,
		pMultisampleState   = &multi_sample,
		pDepthStencilState  = &config.depth_stencil,
		pColorBlendState    = &color_blend,
		pDynamicState       = &dynamic_state_info,
		layout              = layout,
		// renderPass:          RenderPass,
		// subpass:             u32,
		// basePipelineHandle:  Pipeline,
		// basePipelineIndex:   i32,
	}

	pipeline: vk.Pipeline
	vk_check(vk.CreateGraphicsPipelines(device, 0, 1, &graphics_pipeline, nil, &pipeline))

	return Pipeline{layout = layout, pipeline = pipeline}
}

pipeline_create_compute :: proc(ctx: ^Context, config: ^ComputePipelineConfig, stage: ShaderStageDesc) -> Pipeline {
	device := ctx.device
	layout_info := pipeline_build_layout_info(
		&config.descriptor_layouts,
		config.descriptor_layout_count,
		&config.push_constant_range,
	)

	layout: vk.PipelineLayout
	vk_check(vk.CreatePipelineLayout(device, &layout_info, nil, &layout))

	compute_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		stage  = shader_stage_info(stage),
		layout = layout,
	}

	pipeline: vk.Pipeline
	vk_check(vk.CreateComputePipelines(device, 0, 1, &compute_info, nil, &pipeline))

	return Pipeline{layout = layout, pipeline = pipeline}
}

pipeline_destroy :: proc(ctx: ^Context, pipeline: Pipeline) {
	vk.DestroyPipeline(ctx.device, pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(ctx.device, pipeline.layout, nil)
}

pipeline_build_layout_info :: proc(
	descriptor_layouts: ^[8]vk.DescriptorSetLayout,
	descriptor_layout_count: u32,
	push_constant_range: ^vk.PushConstantRange,
) -> vk.PipelineLayoutCreateInfo {
	info := vk.PipelineLayoutCreateInfo {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = descriptor_layout_count,
	}
	if descriptor_layout_count > 0 {
		info.pSetLayouts = &descriptor_layouts[0]
	}
	if push_constant_range.size > 0 {
		info.pushConstantRangeCount = 1
		info.pPushConstantRanges = push_constant_range
	}
	return info
}

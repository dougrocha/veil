package backend

import vk "vendor:vulkan"

Pipeline :: struct {
	layout:   vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

pipeline_bind :: proc(
	cmd: CommandBuffer,
	pipeline: Pipeline,
	bind_point: vk.PipelineBindPoint = .GRAPHICS,
	desc_sets: []vk.DescriptorSet = {},
) {
	raw_cmd := vk.CommandBuffer(cmd)
	vk.CmdBindPipeline(raw_cmd, bind_point, pipeline.pipeline)

	if len(desc_sets) > 0 {
		vk.CmdBindDescriptorSets(
			raw_cmd,
			bind_point,
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
	stages: vk.ShaderStageFlags,
	data: ^$T,
	offset: u32 = 0,
) {
	vk.CmdPushConstants(vk.CommandBuffer(cmd), pipeline.layout, stages, offset, u32(size_of(T)), data)
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
	vk.CmdSetViewport(vk.CommandBuffer(cmd), 0, 1, &viewport)
}

pipeline_set_scissor :: proc(cmd: CommandBuffer, width: u32, height: u32, offset_x: i32 = 0, offset_y: i32 = 0) {
	scissor := vk.Rect2D {
		offset = {offset_x, offset_y},
		extent = {width, height},
	}
	vk.CmdSetScissor(vk.CommandBuffer(cmd), 0, 1, &scissor)
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

pipeline_config_set_descriptor_layouts :: proc(config: ^GraphicsPipelineConfig, layouts: []vk.DescriptorSetLayout) {
	for layout, i in layouts {
		config.descriptor_layouts[i] = layout
	}
	config.descriptor_layout_count = u32(len(layouts))
}


GraphicsPipelineConfig :: struct {
	viewport:                 vk.PipelineViewportStateCreateInfo,
	input_assembly:           vk.PipelineInputAssemblyStateCreateInfo,
	rasterization:            vk.PipelineRasterizationStateCreateInfo,
	multi_sample:             vk.PipelineMultisampleStateCreateInfo,
	color_blend_attachment:   vk.PipelineColorBlendAttachmentState,
	color_blend:              vk.PipelineColorBlendStateCreateInfo,
	depth_stencil:            vk.PipelineDepthStencilStateCreateInfo,
	dynamic_states:           [3]vk.DynamicState,
	dynamic_state_info:       vk.PipelineDynamicStateCreateInfo,
	color_attachment_formats: [8]vk.Format,
	color_attachment_count:   u32,
	rendering_info:           vk.PipelineRenderingCreateInfo,
	descriptor_layouts:       [8]vk.DescriptorSetLayout,
	descriptor_layout_count:  u32,
	push_constant_range:      vk.PushConstantRange,
}

ComputePipelineConfig :: struct {
	descriptor_layouts:      [8]vk.DescriptorSetLayout,
	descriptor_layout_count: u32,
	push_constant_range:     vk.PushConstantRange,
}

PipelineConfig :: union {
	^GraphicsPipelineConfig,
	^ComputePipelineConfig,
}

pipeline_default_config :: proc(config: ^GraphicsPipelineConfig) {
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

	config.dynamic_states = {.VIEWPORT, .SCISSOR, .DEPTH_BIAS}
	config.dynamic_state_info = {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(config.dynamic_states)),
		pDynamicStates    = raw_data(&config.dynamic_states),
	}

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
		pAttachments    = &config.color_blend_attachment,
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

	config.color_attachment_formats[0] = vk.Format(DRAW_FORMAT)
	config.color_attachment_count = 1
	config.rendering_info = {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = config.color_attachment_count,
		pColorAttachmentFormats = &config.color_attachment_formats[0],
		depthAttachmentFormat   = DEPTH_FORMAT,
	}
}

pipeline_create :: proc(
	device: vk.Device,
	config: ^GraphicsPipelineConfig,
	stages: []ShaderStageDesc,
) -> Pipeline {
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

	graphics_pipeline := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &config.rendering_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &config.input_assembly,
		// pTessellationState:  ^PipelineTessellationStateCreateInfo,
		pViewportState      = &config.viewport,
		pRasterizationState = &config.rasterization,
		pMultisampleState   = &config.multi_sample,
		pDepthStencilState  = &config.depth_stencil,
		pColorBlendState    = &config.color_blend,
		pDynamicState       = &config.dynamic_state_info,
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

pipeline_create_compute :: proc(
	device: vk.Device,
	config: ^ComputePipelineConfig,
	stage: ShaderStageDesc,
) -> Pipeline {
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

pipeline_destroy :: proc(ctx: ^VulkanContext, pipeline: Pipeline) {
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


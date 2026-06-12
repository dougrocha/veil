package graphics

import vk "vendor:vulkan"

VERTEX_ENTRY :: "vertex_main"
FRAGMENT_MAIN :: "fragment_main"
COMPUTE_MAIN :: "compute_main"

Pipeline :: struct {
	layout:   vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

create_graphics_pipeline :: proc(self: ^Engine) -> Pipeline {
	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX, .FRAGMENT},
		offset     = 0,
		size       = size_of(PushConstants),
	}

	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &self.descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}

	pipeline: Pipeline
	vk_check(vk.CreatePipelineLayout(self.device, &pipeline_layout_info, nil, &pipeline.layout))

	shader_stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = self.shader_module,
			pName = VERTEX_ENTRY,
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = self.shader_module,
			pName = FRAGMENT_MAIN,
		},
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly_info := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	depth_stencil_info := vk.PipelineDepthStencilStateCreateInfo {
		sType                 = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable       = true,
		depthWriteEnable      = true,
		depthCompareOp        = .LESS,
		stencilTestEnable     = false,
		depthBoundsTestEnable = false,
	}

	viewport_info := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = nil,
		scissorCount  = 1,
		pScissors     = nil,
	}

	raster_info := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		cullMode                = {.BACK},
		frontFace               = .COUNTER_CLOCKWISE,
		depthBiasEnable         = false,
		lineWidth               = 1.0,
	}

	multisample_info := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = self.msaa_samples,
		sampleShadingEnable  = false,
	}

	color_blend_attach_state := vk.PipelineColorBlendAttachmentState {
		blendEnable    = false,
		colorWriteMask = {.R, .G, .B, .A},
	}

	blend_info := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attach_state,
	}

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	color_format := vk.Format(SWAPCHAIN_FORMAT)
	render_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_format,
		depthAttachmentFormat   = DEPTH_FORMAT,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &render_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly_info,
		pViewportState      = &viewport_info,
		pRasterizationState = &raster_info,
		pMultisampleState   = &multisample_info,
		pDepthStencilState  = &depth_stencil_info,
		pColorBlendState    = &blend_info,
		pDynamicState       = &dynamic_state_info,
		layout              = pipeline.layout,
	}

	vk_check(vk.CreateGraphicsPipelines(self.device, 0, 1, &pipeline_info, nil, &pipeline.pipeline))

	return pipeline
}


package graphics

import "core:log"

import vk "vendor:vulkan"

Pipeline :: struct {
	layout:   vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

pipeline_bind :: proc(
	cmd: vk.CommandBuffer,
	pipeline: Pipeline,
	bind_point: vk.PipelineBindPoint = .GRAPHICS,
	desc_sets: []vk.DescriptorSet = {},
) {
	vk.CmdBindPipeline(cmd, bind_point, pipeline.pipeline)

	if len(desc_sets) > 0 {
		vk.CmdBindDescriptorSets(cmd, bind_point, pipeline.layout, 0, u32(len(desc_sets)), raw_data(desc_sets), 0, nil)
	}
}

pipeline_push :: proc(
	cmd: vk.CommandBuffer,
	pipeline: Pipeline,
	stages: vk.ShaderStageFlags,
	data: ^$T,
	offset: u32 = 0,
) {
	vk.CmdPushConstants(cmd, pipeline.layout, stages, offset, u32(size_of(T)), data)
}

pipeline_set_viewport :: proc(cmd: vk.CommandBuffer, width: f32, height: f32) {
	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = width,
		height   = height,
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
}

pipeline_set_scissor :: proc(cmd: vk.CommandBuffer, width: u32, height: u32, offset_x: i32 = 0, offset_y: i32 = 0) {
	scissor := vk.Rect2D {
		offset = {offset_x, offset_y},
		extent = {width, height},
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)
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
	config.depth_stencil_info.depthTestEnable = false
	config.depth_stencil_info.depthWriteEnable = false
}

PipelineKind :: enum u8 {
	Shadow,
	Shadow_Directional,
	Mesh,
	Skybox,
	UI,
	Particle_Draw,
	Particle_Compute,
	Debug_Shadow,
}

PipelineRegistry :: struct {
	pipelines:    [PipelineKind]Pipeline,
	configs:      [PipelineKind]PipelineConfig, // nil (no case matched) for unregistered kinds
	shaders:      [PipelineKind]ShaderHandle,
	module_names: [PipelineKind]string,
}

pipeline_register :: proc(
	self: ^Engine,
	kind: PipelineKind,
	shader: ShaderHandle,
	config: ^GraphicsPipelineConfig,
	shader_stages: []vk.PipelineShaderStageCreateInfo,
) {
	self.pipeline_registry.pipelines[kind] = pipeline_create(self.vk_ctx.device, config, shader_stages)
	self.pipeline_registry.configs[kind] = config
	self.pipeline_registry.shaders[kind] = shader
}

pipeline_register_compute :: proc(
	self: ^Engine,
	kind: PipelineKind,
	shader: ShaderHandle,
	config: ^ComputePipelineConfig,
	shader_stage: vk.PipelineShaderStageCreateInfo,
) {
	self.pipeline_registry.pipelines[kind] = pipeline_create_compute(self.vk_ctx.device, config, shader_stage)
	self.pipeline_registry.configs[kind] = config
	self.pipeline_registry.shaders[kind] = shader
}

get_pipeline :: #force_inline proc(reg: ^PipelineRegistry, kind: PipelineKind) -> Pipeline {
	return reg.pipelines[kind]
}

pipeline_rebuild :: proc(self: ^Engine, kind: PipelineKind, new_shader_stages: []vk.PipelineShaderStageCreateInfo) {
	config := self.pipeline_registry.configs[kind]
	if config == nil {
		log.errorf("pipeline_rebuild '%v': no config registered", kind)
		return
	}

	old_pipeline := self.pipeline_registry.pipelines[kind]

	vk.DeviceWaitIdle(self.vk_ctx.device)
	vk.DestroyPipeline(self.vk_ctx.device, old_pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(self.vk_ctx.device, old_pipeline.layout, nil)

	switch cfg in config {
	case ^GraphicsPipelineConfig:
		self.pipeline_registry.pipelines[kind] = pipeline_create(self.vk_ctx.device, cfg, new_shader_stages)
	case ^ComputePipelineConfig:
		self.pipeline_registry.pipelines[kind] = pipeline_create_compute(self.vk_ctx.device, cfg, new_shader_stages[0])
	case nil:
	}
	log.infof("Rebuilt pipeline: %v", kind)
}

destroy_pipeline_registry :: proc(device: vk.Device, reg: ^PipelineRegistry) {
	for pipeline in reg.pipelines {
		vk.DestroyPipeline(device, pipeline.pipeline, nil)
		vk.DestroyPipelineLayout(device, pipeline.layout, nil)
	}
	for config in reg.configs {
		switch cfg in config {
		case ^GraphicsPipelineConfig:
			free(cfg)
		case ^ComputePipelineConfig:
			free(cfg)
		case nil:
		}
	}
}

pipeline_reload :: proc(self: ^Engine, kind: PipelineKind, module_name: string) {
	config := self.pipeline_registry.configs[kind]

	// load_shader reuses the same handle on a repeat load and destroys the old vk.ShaderModule
	// itself, so there's nothing to manually destroy here.
	switch _ in config {
	case ^GraphicsPipelineConfig:
		new_handle, compile_ok := load_shader(self, module_name, {VERTEX_ENTRY, FRAGMENT_MAIN})
		if !compile_ok {
			log.errorf("pipeline_reload '%v': shader compilation failed, keeping old pipeline", kind)
			return
		}
		shader_module := get_shader(self, new_handle)
		new_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = shader_module,
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = shader_module,
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_rebuild(self, kind, new_stages)

	case ^ComputePipelineConfig:
		new_handle, compile_ok := load_shader(self, module_name, {COMPUTE_MAIN})
		if !compile_ok {
			log.errorf("pipeline_reload '%v': shader compilation failed, keeping old pipeline", kind)
			return
		}
		shader_module := get_shader(self, new_handle)
		new_stage := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.COMPUTE},
			module = shader_module,
			pName  = cstring(COMPUTE_MAIN),
		}
		pipeline_rebuild(self, kind, []vk.PipelineShaderStageCreateInfo{new_stage})

	case nil:
		log.errorf("pipeline_reload '%v': no config registered", kind)
	}
}

/*
build_pipeline :: proc(vk_ctx: ^VulkanContext, shader: vk.ShaderModule, desc: PipelineDescriptor) -> Pipeline {
	desc := desc // local copy so arrays are addressable
	push_constant_range := vk.PushConstantRange {
		stageFlags = desc.push_constant_stages,
		offset     = 0,
		size       = desc.push_constant_size,
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = desc.descriptor_layout_count,
		pSetLayouts    = &desc.descriptor_layouts[0],
	}
	if desc.push_constant_size > 0 {
		layout_info.pushConstantRangeCount = 1
		layout_info.pPushConstantRanges = &push_constant_range
	}

	pipeline: Pipeline
	vk_check(vk.CreatePipelineLayout(vk_ctx.device, &layout_info, nil, &pipeline.layout))

	#partial switch desc.type {
	case .COMPUTE:
		stage := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.COMPUTE},
			module = shader,
			pName  = COMPUTE_MAIN,
		}
		compute_info := vk.ComputePipelineCreateInfo {
			sType  = .COMPUTE_PIPELINE_CREATE_INFO,
			stage  = stage,
			layout = pipeline.layout,
		}
		vk_check(vk.CreateComputePipelines(vk_ctx.device, 0, 1, &compute_info, nil, &pipeline.pipeline))

	case .GRAPHICS:
		vert_stage := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.VERTEX},
			module = shader,
			pName  = desc.vertex_entry,
		}
		frag_stage := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.FRAGMENT},
			module = shader,
			pName  = desc.fragment_entry,
		}

		shader_stages: [dynamic]vk.PipelineShaderStageCreateInfo
		defer delete(shader_stages)
		append(&shader_stages, vert_stage)
		if desc.fragment_entry != nil {
			append(&shader_stages, frag_stage)
		}

		vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		}

		input_assembly_info := vk.PipelineInputAssemblyStateCreateInfo {
			sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = desc.topology,
		}

		depth_stencil_info := vk.PipelineDepthStencilStateCreateInfo {
			sType            = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable  = b32(desc.depth_test),
			depthWriteEnable = b32(desc.depth_write),
			depthCompareOp   = desc.depth_compare_op,
		}

		viewport_info := vk.PipelineViewportStateCreateInfo {
			sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount  = 1,
		}

		raster_info := vk.PipelineRasterizationStateCreateInfo {
			sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode             = .FILL,
			cullMode                = desc.cull_mode,
			frontFace               = .COUNTER_CLOCKWISE,
			lineWidth               = 1.0,
			depthBiasEnable         = b32(desc.depth_bias_enable),
			depthBiasConstantFactor = desc.depth_bias_constant_factor,
			depthBiasClamp          = desc.depth_bias_clamp,
			depthBiasSlopeFactor    = desc.depth_bias_slope_factor,
		}

		multisample_info := vk.PipelineMultisampleStateCreateInfo {
			sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = desc.sample_count if desc.sample_count != {} else {._1},
		}

		color_blend_attach := vk.PipelineColorBlendAttachmentState {
			colorWriteMask = {.R, .G, .B, .A},
		}
		if blend, has_blend := desc.blend.?; has_blend {
			color_blend_attach.blendEnable = true
			switch blend {
			case .Alpha:
				color_blend_attach.colorBlendOp = .ADD
				color_blend_attach.srcColorBlendFactor = .SRC_ALPHA
				color_blend_attach.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
				color_blend_attach.alphaBlendOp = .ADD
				color_blend_attach.srcAlphaBlendFactor = .ONE
				color_blend_attach.dstAlphaBlendFactor = .ZERO
			case .Additive:
				color_blend_attach.colorBlendOp = .ADD
				color_blend_attach.srcColorBlendFactor = .SRC_ALPHA
				color_blend_attach.dstColorBlendFactor = .ONE
				color_blend_attach.alphaBlendOp = .ADD
				color_blend_attach.srcAlphaBlendFactor = .ONE
				color_blend_attach.dstAlphaBlendFactor = .ZERO
			}
		}

		blend_attachments := make([]vk.PipelineColorBlendAttachmentState, desc.color_format_count)
		defer delete(blend_attachments)
		for &a in blend_attachments {
			a = color_blend_attach
		}

		blend_info := vk.PipelineColorBlendStateCreateInfo {
			sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = desc.color_format_count,
			pAttachments    = raw_data(blend_attachments),
		}

		dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR, .DEPTH_BIAS}
		dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
			sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = u32(len(dynamic_states)),
			pDynamicStates    = raw_data(dynamic_states),
		}
		render_info := vk.PipelineRenderingCreateInfo {
			sType                   = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount    = desc.color_format_count,
			pColorAttachmentFormats = &desc.color_formats[0],
			depthAttachmentFormat   = desc.depth_format,
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

		vk_check(vk.CreateGraphicsPipelines(vk_ctx.device, 0, 1, &pipeline_info, nil, &pipeline.pipeline))
	}

	return pipeline
}
*/

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

pipeline_create :: proc(
	device: vk.Device,
	config: ^GraphicsPipelineConfig,
	shader_stages: []vk.PipelineShaderStageCreateInfo,
) -> Pipeline {
	layout_info := pipeline_build_layout_info(
		&config.descriptor_layouts,
		config.descriptor_layout_count,
		&config.push_constant_range,
	)

	layout: vk.PipelineLayout
	vk_check(vk.CreatePipelineLayout(device, &layout_info, nil, &layout))

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	graphics_pipeline := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &config.rendering_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &config.input_assembly_info,
		// pTessellationState:  ^PipelineTessellationStateCreateInfo,
		pViewportState      = &config.viewport_info,
		pRasterizationState = &config.rasterization_info,
		pMultisampleState   = &config.multi_sample_info,
		pDepthStencilState  = &config.depth_stencil_info,
		pColorBlendState    = &config.color_blend_info,
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
	shader_stage: vk.PipelineShaderStageCreateInfo,
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
		stage  = shader_stage,
		layout = layout,
	}

	pipeline: vk.Pipeline
	vk_check(vk.CreateComputePipelines(device, 0, 1, &compute_info, nil, &pipeline))

	return Pipeline{layout = layout, pipeline = pipeline}
}

GraphicsPipelineConfig :: struct {
	viewport_info:            vk.PipelineViewportStateCreateInfo,
	input_assembly_info:      vk.PipelineInputAssemblyStateCreateInfo,
	rasterization_info:       vk.PipelineRasterizationStateCreateInfo,
	multi_sample_info:        vk.PipelineMultisampleStateCreateInfo,
	color_blend_attachment:   vk.PipelineColorBlendAttachmentState,
	color_blend_info:         vk.PipelineColorBlendStateCreateInfo,
	depth_stencil_info:       vk.PipelineDepthStencilStateCreateInfo,
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
	config.viewport_info = {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		pViewports    = nil,
		viewportCount = 1,
		pScissors     = nil,
		scissorCount  = 1,
	}

	config.input_assembly_info = {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	config.rasterization_info = {
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

	config.multi_sample_info = {
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

	config.color_blend_info = {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &config.color_blend_attachment,
		blendConstants  = {0, 0, 0, 0},
	}

	config.depth_stencil_info = {
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


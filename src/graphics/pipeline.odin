package graphics

import "core:log"

import vk "vendor:vulkan"

Pipeline :: struct {
	layout:   vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

PipelineType :: enum {
	Graphics,
	Compute,
}

BlendMode :: enum {
	Alpha,
	Additive,
}

PipelineDescriptor :: struct {
	shader:               ShaderHandle,
	type:                 PipelineType,
	topology:             vk.PrimitiveTopology,
	cull_mode:            vk.CullModeFlags,
	depth_test:           bool,
	depth_write:          bool,
	depth_compare_op:     vk.CompareOp,
	blend:                Maybe(BlendMode),
	push_constant_size:   u32,
	push_constant_stages: vk.ShaderStageFlags,
	descriptor_layout:    Maybe(vk.DescriptorSetLayout),
	sample_count:         vk.SampleCountFlags,
}

pipeline_descriptor_default :: proc() -> PipelineDescriptor {
	return PipelineDescriptor {
		type = .Graphics,
		topology = .TRIANGLE_LIST,
		cull_mode = {.BACK},
		depth_test = true,
		depth_write = true,
		depth_compare_op = .LESS,
		blend = nil,
		push_constant_size = size_of(PushConstants),
		push_constant_stages = {.VERTEX, .FRAGMENT},
		descriptor_layout = nil,
	}
}

PipelineEntry :: struct {
	pipeline:   Pipeline,
	descriptor: PipelineDescriptor,
}

PipelineRegistry :: struct {
	entries: map[string]PipelineEntry,
}

register_pipeline :: proc(self: ^Engine, reg: ^PipelineRegistry, name: string, desc: PipelineDescriptor) {
	reg.entries[name] = PipelineEntry {
		pipeline   = build_pipeline(self, desc),
		descriptor = desc,
	}
}

get_pipeline :: proc(reg: ^PipelineRegistry, name: string) -> Pipeline {
	return reg.entries[name].pipeline
}

destroy_pipeline_registry :: proc(device: vk.Device, reg: ^PipelineRegistry) {
	for _, entry in reg.entries {
		vk.DestroyPipeline(device, entry.pipeline.pipeline, nil)
		vk.DestroyPipelineLayout(device, entry.pipeline.layout, nil)
	}
	delete(reg.entries)
}

reload_pipeline :: proc(self: ^Engine, name: string) {
	entry, ok := &self.pipeline_registry.entries[name]
	if !ok {
		log.errorf("reload_pipeline: unknown pipeline '%s'", name)
		return
	}

	// find the shader module name by searching name_to_handle
	module_name: string
	for n, h in self.shader_system.name_to_handle {
		if h == entry.descriptor.shader {
			module_name = n
			break
		}
	}

	if module_name == "" {
		log.errorf("reload_pipeline '%s': could not find shader module name", name)
		return
	}

	// determine entry points from pipeline type
	entry_points: []string
	switch entry.descriptor.type {
	case .Graphics:
		entry_points = {VERTEX_ENTRY, FRAGMENT_MAIN}
	case .Compute:
		entry_points = {COMPUTE_MAIN}
	}

	_, compile_ok := load_shader(self, module_name, entry_points)
	if !compile_ok {
		log.errorf("reload_pipeline '%s': shader compilation failed, keeping old pipeline", name)
		return
	}

	vk.DeviceWaitIdle(self.vk_ctx.device)
	vk.DestroyPipeline(self.vk_ctx.device, entry.pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(self.vk_ctx.device, entry.pipeline.layout, nil)

	entry.pipeline = build_pipeline(self, entry.descriptor)
	log.infof("Reloaded pipeline: %s", name)
}

build_pipeline :: proc(self: ^Engine, desc: PipelineDescriptor) -> Pipeline {
	push_constant_range := vk.PushConstantRange {
		stageFlags = desc.push_constant_stages,
		offset     = 0,
		size       = desc.push_constant_size,
	}

	layout_info := vk.PipelineLayoutCreateInfo {
		sType = .PIPELINE_LAYOUT_CREATE_INFO,
	}
	if desc.push_constant_size > 0 {
		layout_info.pushConstantRangeCount = 1
		layout_info.pPushConstantRanges = &push_constant_range
	}
	if layout, ok := desc.descriptor_layout.?; ok {
		layout_info.setLayoutCount = 1
		layout_info.pSetLayouts = &layout
	}

	pipeline: Pipeline
	vk_check(vk.CreatePipelineLayout(self.vk_ctx.device, &layout_info, nil, &pipeline.layout))

	shader_module := get_shader(self, desc.shader)

	switch desc.type {
	case .Compute:
		stage := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.COMPUTE},
			module = shader_module,
			pName  = COMPUTE_MAIN,
		}
		compute_info := vk.ComputePipelineCreateInfo {
			sType  = .COMPUTE_PIPELINE_CREATE_INFO,
			stage  = stage,
			layout = pipeline.layout,
		}
		vk_check(vk.CreateComputePipelines(self.vk_ctx.device, 0, 1, &compute_info, nil, &pipeline.pipeline))

	case .Graphics:
		shader_stages := [2]vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = shader_module,
				pName = VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = shader_module,
				pName = FRAGMENT_MAIN,
			},
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
			sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			cullMode    = desc.cull_mode,
			frontFace   = .COUNTER_CLOCKWISE,
			lineWidth   = 1.0,
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

		blend_info := vk.PipelineColorBlendStateCreateInfo {
			sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = 1,
			pAttachments    = &color_blend_attach,
		}

		dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
		dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
			sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = u32(len(dynamic_states)),
			pDynamicStates    = raw_data(dynamic_states),
		}

		color_format := vk.Format(DRAW_FORMAT)
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

		vk_check(vk.CreateGraphicsPipelines(self.vk_ctx.device, 0, 1, &pipeline_info, nil, &pipeline.pipeline))
	}

	return pipeline
}

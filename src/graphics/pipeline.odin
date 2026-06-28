package graphics

import "core:log"

import vk "vendor:vulkan"

Pipeline :: struct {
	layout:   vk.PipelineLayout,
	pipeline: vk.Pipeline,
}

BlendMode :: enum {
	Alpha,
	Additive,
}

PipelineDescriptor :: struct {
	shader:                     ShaderHandle,
	type:                       vk.PipelineBindPoint,
	topology:                   vk.PrimitiveTopology,
	cull_mode:                  vk.CullModeFlags,
	depth_test:                 bool,
	depth_write:                bool,
	depth_compare_op:           vk.CompareOp,
	depth_bias_enable:          bool,
	depth_bias_constant_factor: f32,
	depth_bias_clamp:           f32,
	depth_bias_slope_factor:    f32,
	blend:                      Maybe(BlendMode),
	push_constant_size:         u32,
	push_constant_stages:       vk.ShaderStageFlags,
	descriptor_layouts:       [8]vk.DescriptorSetLayout,
	descriptor_layout_count:  u32,
	sample_count:             vk.SampleCountFlags,
	color_formats:            [4]vk.Format,
	color_format_count:       u32,
	depth_format:               vk.Format,
	vertex_entry:               cstring,
	fragment_entry:             cstring, // nil = vertex-only depth pass
}

make_pipeline_descriptor :: proc(
	shader: ShaderHandle,
	type: vk.PipelineBindPoint = .GRAPHICS,
	topology: vk.PrimitiveTopology = .TRIANGLE_LIST,
	cull_mode: vk.CullModeFlags = {.BACK},
	depth_test: bool = true,
	depth_write: bool = true,
	depth_compare_op: vk.CompareOp = .LESS,
	depth_bias_enable: bool = false,
	depth_bias_constant_factor: f32 = 0.0,
	depth_bias_clamp: f32 = 0.0,
	depth_bias_slope_factor: f32 = 0.0,
	blend: Maybe(BlendMode) = nil,
	push_constant_size: u32 = size_of(PushConstants),
	push_constant_stages: vk.ShaderStageFlags = {.VERTEX, .FRAGMENT},
	descriptor_layouts: []vk.DescriptorSetLayout = {},
	sample_count: vk.SampleCountFlags = {._1},
	color_formats: []vk.Format = {vk.Format(DRAW_FORMAT)},

	depth_format: vk.Format = DEPTH_FORMAT,
	vertex_entry: cstring = DEFAULT_VERTEX_ENTRY,
	fragment_entry: cstring = DEFAULT_FRAGMENT_ENTRY,
) -> PipelineDescriptor {
	desc := PipelineDescriptor {
		shader                     = shader,
		type                       = type,
		topology                   = topology,
		cull_mode                  = cull_mode,
		depth_test                 = depth_test,
		depth_write                = depth_write,
		depth_compare_op           = depth_compare_op,
		depth_bias_enable          = depth_bias_enable,
		depth_bias_constant_factor = depth_bias_constant_factor,
		depth_bias_clamp           = depth_bias_clamp,
		depth_bias_slope_factor    = depth_bias_slope_factor,
		blend                      = blend,
		push_constant_size         = push_constant_size,
		push_constant_stages       = push_constant_stages,
		sample_count               = sample_count,
		depth_format               = depth_format,
		vertex_entry               = vertex_entry,
		fragment_entry             = fragment_entry,
		color_format_count         = u32(len(color_formats)),
		descriptor_layout_count    = u32(len(descriptor_layouts)),
	}
	for f, i in color_formats      do desc.color_formats[i]      = f
	for l, i in descriptor_layouts do desc.descriptor_layouts[i] = l
	return desc
}

PipelineEntry :: struct {
	pipeline:   Pipeline,
	descriptor: PipelineDescriptor,
}

PipelineRegistry :: struct {
	entries: map[string]PipelineEntry,
}

register_pipeline :: proc(self: ^Engine, name: string, desc: PipelineDescriptor) {
	self.pipeline_registry.entries[name] = PipelineEntry {
		pipeline   = build_pipeline(&self.vk_ctx, get_shader(self, desc.shader), desc),
		descriptor = desc,
	}
}

get_pipeline :: proc(reg: ^PipelineRegistry, name: string) -> Pipeline {
	entry, ok := reg.entries[name]
	if !ok {
		log.panicf("get_pipeline: unknown pipeline '%s'", name)
	}
	return entry.pipeline
}

get_pipeline_entry :: proc(reg: ^PipelineRegistry, name: string) -> PipelineEntry {
	entry, ok := reg.entries[name]
	if !ok {
		log.panicf("get_pipeline_entry: unknown pipeline '%s'", name)
	}
	return entry
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
	#partial switch entry.descriptor.type {
	case .GRAPHICS:
		if entry.descriptor.fragment_entry != nil {
			entry_points = {VERTEX_ENTRY, FRAGMENT_MAIN}
		} else {
			entry_points = {VERTEX_ENTRY}
		}
	case .COMPUTE:
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

	entry.pipeline = build_pipeline(&self.vk_ctx, get_shader(self, entry.descriptor.shader), entry.descriptor)
	log.infof("Reloaded pipeline: %s", name)
}

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

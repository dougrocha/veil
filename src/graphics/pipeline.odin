package graphics

import "core:log"

import vk "vendor:vulkan"

VERTEX_ENTRY :: "vertex_main"
FRAGMENT_MAIN :: "fragment_main"
COMPUTE_MAIN :: "compute_main"

create_descriptor_set_layout :: proc(self: ^Engine) {
	bindings := []vk.DescriptorSetLayoutBinding {
		{binding = 0, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX, .FRAGMENT}},
		{binding = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings[:]),
	}

	vk_check(vk.CreateDescriptorSetLayout(self.device, &layout_info, nil, &self.descriptor_set_layout))
}

create_graphics_pipeline :: proc(self: ^Engine) -> vk.Pipeline {
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

	log.debug("Creating pipeline layout...")
	vk_check(vk.CreatePipelineLayout(self.device, &pipeline_layout_info, nil, &self.pipeline_layout))
	log.debug("Pipeline layout created")

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

	binding_description := vertex_binding_description()
	attribute_descriptions := vertex_attribute_descriptions()
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		// pVertexBindingDescriptions      = &binding_description,
		// vertexBindingDescriptionCount   = 1,
		// pVertexAttributeDescriptions    = raw_data(attribute_descriptions[:]),
		// vertexAttributeDescriptionCount = u32(len(attribute_descriptions)),
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
		layout              = self.pipeline_layout,
	}

	log.debug("Creating graphics pipeline...")
	pipeline: vk.Pipeline
	vk_check(vk.CreateGraphicsPipelines(self.device, 0, 1, &pipeline_info, nil, &pipeline))

	return pipeline
}

create_descriptor_pool :: proc(engine: ^Engine) {
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = MAX_FRAMES_IN_FLIGHT,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	vk_check(vk.CreateDescriptorPool(engine.device, &pool_info, nil, &engine.descriptor_pool))
}

create_descriptor_sets :: proc(engine: ^Engine) {
	layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout{engine.descriptor_set_layout, engine.descriptor_set_layout}

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = engine.descriptor_pool,
		descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
		pSetLayouts        = raw_data(layouts[:]),
	}

	vk_check(vk.AllocateDescriptorSets(engine.device, &alloc_info, raw_data(engine.descriptor_sets[:])))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer_info := vk.DescriptorBufferInfo {
			buffer = engine.uniform_buffers[i],
			offset = 0,
			range  = size_of(UniformBufferObject),
		}

		image_info := vk.DescriptorImageInfo {
			sampler     = engine.texture_sampler,
			imageView   = engine.texture_image_view,
			imageLayout = .READ_ONLY_OPTIMAL,
		}

		descriptor_write := []vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = engine.descriptor_sets[i],
				dstBinding = 0,
				dstArrayElement = 0,
				descriptorCount = 1,
				descriptorType = .UNIFORM_BUFFER,
				pBufferInfo = &buffer_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = engine.descriptor_sets[i],
				dstBinding = 1,
				dstArrayElement = 0,
				descriptorCount = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				pImageInfo = &image_info,
			},
		}

		vk.UpdateDescriptorSets(engine.device, u32(len(descriptor_write)), raw_data(descriptor_write), 0, nil)
	}
}


package graphics

import vk "vendor:vulkan"

create_descriptor_set_layout :: proc(self: ^Engine) {
	bindings := []vk.DescriptorSetLayoutBinding {
		{binding = 0, descriptorType = .UNIFORM_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX, .FRAGMENT}},
		{
			binding = 1,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = MAX_TEXTURES,
			stageFlags = {.FRAGMENT},
		},
	}

	binding_flags := []vk.DescriptorBindingFlags{{}, {.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}}

	binding_flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = u32(len(binding_flags)),
		pBindingFlags = raw_data(binding_flags),
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &binding_flags_info,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings[:]),
	}

	vk_check(vk.CreateDescriptorSetLayout(self.device, &layout_info, nil, &self.descriptor_set_layout))
}

create_descriptor_pool :: proc(engine: ^Engine) {
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .UNIFORM_BUFFER, descriptorCount = MAX_FRAMES_IN_FLIGHT},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_FRAMES_IN_FLIGHT * MAX_TEXTURES},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET, .UPDATE_AFTER_BIND},
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

		descriptor_write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = engine.descriptor_sets[i],
			dstBinding      = 0,
			dstArrayElement = 0,
			descriptorCount = 1,
			descriptorType  = .UNIFORM_BUFFER,
			pBufferInfo     = &buffer_info,
		}

		vk.UpdateDescriptorSets(engine.device, 1, &descriptor_write, 0, nil)
	}
}

update_texture_descriptor :: proc(engine: ^Engine, index: u32) {
	t := &engine.textures[index]
	image_info := vk.DescriptorImageInfo {
		sampler     = t.sampler,
		imageView   = t.image_view,
		imageLayout = .READ_ONLY_OPTIMAL,
	}

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		descriptor_write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = engine.descriptor_sets[i],
			dstBinding      = 1,
			dstArrayElement = index,
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = &image_info,
		}
		vk.UpdateDescriptorSets(engine.device, 1, &descriptor_write, 0, nil)
	}
}


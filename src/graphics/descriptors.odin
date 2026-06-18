package graphics

import vk "vendor:vulkan"

create_descriptor_set_layout :: proc(self: ^Engine) {
	// NOTE: since we only use one sampler for now, we could add a immutable
	// sampler in the set layouts, but all this does is save on memory
	// and give performance boost, not worth the mental overhead right now

	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = MAX_TEXTURES,
			stageFlags = {.FRAGMENT},
		},
	}

	binding_flags := []vk.DescriptorBindingFlags{{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}}

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
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = MAX_FRAMES_IN_FLIGHT * MAX_TEXTURES},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		// NOTE: FREE_DESCRIPTOR_SET forces the driver into a dynamic allocator with fragmentation overhead
		// We never free individual sets (only reset the whole pool), so not adding it keeps the pool
		// as a simple linear bump allocator in the GPU
		// from: amds VulkanFastPaths
		flags         = {.UPDATE_AFTER_BIND},
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
}

// Uploads the texture using the index
//
// Uploads the texture memory into the larger GPU memory that gets sent
// in shader, this is the TextureSample list
update_texture_descriptor :: proc(engine: ^Engine, index: u32) {
	t := &engine.texture_system.textures[index]
	image_info := vk.DescriptorImageInfo {
		sampler     = t.sampler,
		imageView   = t.image_view,
		imageLayout = .READ_ONLY_OPTIMAL,
	}

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		descriptor_write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = engine.descriptor_sets[i],
			dstBinding      = 0,
			dstArrayElement = index,
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = &image_info,
		}
		vk.UpdateDescriptorSets(engine.device, 1, &descriptor_write, 0, nil)
	}
}

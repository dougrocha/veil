package graphics

import vk "vendor:vulkan"

DescriptorSet :: struct {
	layout: vk.DescriptorSetLayout,
	pool:   vk.DescriptorPool,
	sets:   [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	count:  u32,
}

create_descriptor_set :: proc(
	engine: ^Engine,
	bindings: []vk.DescriptorSetLayoutBinding,
	count: u32 = 1,
	binding_flags: []vk.DescriptorBindingFlags = nil,
	layout_flags: vk.DescriptorSetLayoutCreateFlags = {},
	pool_flags: vk.DescriptorPoolCreateFlags = {},
) -> DescriptorSet {
	assert(count <= MAX_FRAMES_IN_FLIGHT)
	desc: DescriptorSet
	desc.count = count

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		flags        = layout_flags,
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
	}
	binding_flags_info: vk.DescriptorSetLayoutBindingFlagsCreateInfo
	if binding_flags != nil {
		binding_flags_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo {
			sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
			bindingCount  = u32(len(binding_flags)),
			pBindingFlags = raw_data(binding_flags),
		}
		layout_info.pNext = &binding_flags_info
	}
	vk_check(vk.CreateDescriptorSetLayout(engine.vk_ctx.device, &layout_info, nil, &desc.layout))

	pool_sizes := make([]vk.DescriptorPoolSize, len(bindings), context.temp_allocator)
	for b, i in bindings {
		pool_sizes[i] = {
			type            = b.descriptorType,
			descriptorCount = b.descriptorCount * count,
		}
	}
	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = pool_flags,
		maxSets       = count,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}
	vk_check(vk.CreateDescriptorPool(engine.vk_ctx.device, &pool_info, nil, &desc.pool))

	layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout{}
	for i in 0 ..< count do layouts[i] = desc.layout
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = desc.pool,
		descriptorSetCount = count,
		pSetLayouts        = &layouts[0],
	}
	vk_check(vk.AllocateDescriptorSets(engine.vk_ctx.device, &alloc_info, &desc.sets[0]))

	return desc
}

destroy_descriptor_set :: proc(engine: ^Engine, desc: ^DescriptorSet) {
	vk.DestroyDescriptorPool(engine.vk_ctx.device, desc.pool, nil)
	vk.DestroyDescriptorSetLayout(engine.vk_ctx.device, desc.layout, nil)
}

// Writes a texture from the texture system into the descriptor set at the given binding.
// Writes to all sets in the descriptor (all frames).
write_descriptor_texture :: proc(
	engine: ^Engine,
	desc: ^DescriptorSet,
	binding: u32,
	handle: TextureHandle,
	array_element: u32 = 0,
) {
	t := &engine.texture_system.textures.slots[handle.index].value
	image_info := vk.DescriptorImageInfo {
		sampler     = t.sampler,
		imageView   = t.image_view,
		imageLayout = .READ_ONLY_OPTIMAL,
	}
	for i in 0 ..< desc.count {
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = desc.sets[i],
			dstBinding      = binding,
			dstArrayElement = array_element,
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = &image_info,
		}
		vk.UpdateDescriptorSets(engine.vk_ctx.device, 1, &write, 0, nil)
	}
}

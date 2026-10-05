package backend

import vk "vendor:vulkan"

// Descriptors are a way of "describing" the data the GPU is sent.
// Another way we currently have is with Push constants which are easier to understand and read

// Raw per-frame descriptor set handle, e.g. for building the desc_sets slice passed to pipeline_bind.
DescriptorSetHandle :: vk.DescriptorSet

DescriptorBindingFlags :: vk.DescriptorBindingFlags

// SetLayoutBinding: Holds the connection between the CPU and GPU, much like a contract for what will be stored
DescriptorSet :: struct {
	layout: vk.DescriptorSetLayout,
	// pool + sets is where the actual memory lives
	pool:   vk.DescriptorPool,
	sets:   [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	count:  u32,
}

// Create a descriptor layout
descriptor_layout_create :: proc(
	ctx: ^Context,
	bindings: []vk.DescriptorSetLayoutBinding,
	binding_flags: []vk.DescriptorBindingFlags = nil,
	flags: vk.DescriptorSetLayoutCreateFlags = {},
) -> vk.DescriptorSetLayout {
	info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		flags        = flags,
		bindingCount = u32(len(bindings)),
		pBindings    = raw_data(bindings),
	}

	binding_flags_info: vk.DescriptorSetLayoutBindingFlagsCreateInfo
	if binding_flags != nil {
		binding_flags_info = {
			sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
			bindingCount  = u32(len(binding_flags)),
			pBindingFlags = raw_data(binding_flags),
		}
		info.pNext = &binding_flags_info
	}

	layout: vk.DescriptorSetLayout
	vk_check(vk.CreateDescriptorSetLayout(ctx.device, &info, nil, &layout))
	return layout
}

descriptor_layout_destroy :: proc(ctx: ^Context, layout: vk.DescriptorSetLayout) {
	vk.DestroyDescriptorSetLayout(ctx.device, layout, nil)
}

descriptor_pool_create :: proc(
	ctx: ^Context,
	bindings: []vk.DescriptorSetLayoutBinding,
	max_sets: u32,
	flags: vk.DescriptorPoolCreateFlags = {},
) -> vk.DescriptorPool {
	pool_sizes := make([]vk.DescriptorPoolSize, len(bindings), context.temp_allocator)
	for b, i in bindings {
		pool_sizes[i] = {
			type            = b.descriptorType,
			descriptorCount = b.descriptorCount * max_sets,
		}
	}

	info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = flags,
		maxSets       = max_sets,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	pool: vk.DescriptorPool
	vk_check(vk.CreateDescriptorPool(ctx.device, &info, nil, &pool))
	return pool
}

descriptor_pool_destroy :: proc(ctx: ^Context, pool: vk.DescriptorPool) {
	vk.DestroyDescriptorPool(ctx.device, pool, nil)
}

descriptor_sets_allocate :: proc(
	ctx: ^Context,
	pool: vk.DescriptorPool,
	layout: vk.DescriptorSetLayout,
	count: u32,
) -> [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet {
	assert(count <= MAX_FRAMES_IN_FLIGHT)

	layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout{}
	for i in 0 ..< count do layouts[i] = layout

	sets: [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = pool,
		descriptorSetCount = count,
		pSetLayouts        = &layouts[0],
	}
	vk_check(vk.AllocateDescriptorSets(ctx.device, &alloc_info, &sets[0]))
	return sets
}

descriptor_set_create :: proc(
	ctx: ^Context,
	bindings: []vk.DescriptorSetLayoutBinding,
	count: u32 = 1,
	binding_flags: []vk.DescriptorBindingFlags = nil,
	layout_flags: vk.DescriptorSetLayoutCreateFlags = {},
	pool_flags: vk.DescriptorPoolCreateFlags = {},
) -> DescriptorSet {
	layout := descriptor_layout_create(ctx, bindings, binding_flags, layout_flags)
	pool := descriptor_pool_create(ctx, bindings, count, pool_flags)
	sets := descriptor_sets_allocate(ctx, pool, layout, count)

	return DescriptorSet{layout = layout, pool = pool, sets = sets, count = count}
}

descriptor_set_destroy :: proc(ctx: ^Context, desc: ^DescriptorSet) {
	descriptor_pool_destroy(ctx, desc.pool)
	descriptor_layout_destroy(ctx, desc.layout)
}

// Fixed-size array of sampler-backed slots, all COMBINED_IMAGE_SAMPLER/FRAGMENT -
// the shape needed for e.g. the shadow atlas bindings.
descriptor_set_create_sampler_array :: proc(
	ctx: ^Context,
	slot_count: u32,
	count: u32 = MAX_FRAMES_IN_FLIGHT,
) -> DescriptorSet {
	bindings := make([]vk.DescriptorSetLayoutBinding, slot_count, context.temp_allocator)
	for i in 0 ..< slot_count {
		bindings[i] = {
			binding         = i,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		}
	}
	return descriptor_set_create(ctx, bindings, count)
}

// The bindless set, with update-after-bind flags so slots can be sparsely written
// while in flight. Matches the Slang BindlessTextures parameter block: binding 0
// is the Texture2D array, binding 1 the SamplerState array. Textures and samplers
// are indexed independently, so the sampler array only holds a few fixed samplers.
descriptor_set_create_bindless_array :: proc(
	ctx: ^Context,
	texture_count: u32,
	sampler_count: u32,
	count: u32 = MAX_FRAMES_IN_FLIGHT,
) -> DescriptorSet {
	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = texture_count,
			stageFlags = {.FRAGMENT, .COMPUTE},
		},
		{binding = 1, descriptorType = .SAMPLER, descriptorCount = sampler_count, stageFlags = {.FRAGMENT, .COMPUTE}},
	}
	// UPDATE_UNUSED_WHILE_PENDING: texture registration writes a new slot into every frame's
	// set, including ones a submitted frame is still executing.
	binding_flags := []vk.DescriptorBindingFlags {
		DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND, .UPDATE_UNUSED_WHILE_PENDING},
		DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND, .UPDATE_UNUSED_WHILE_PENDING},
	}
	return descriptor_set_create(
		ctx,
		bindings,
		count,
		binding_flags = binding_flags,
		layout_flags = {.UPDATE_AFTER_BIND_POOL},
		pool_flags = {.UPDATE_AFTER_BIND},
	)
}

// Writes the same image/sampler into the given binding across every frame's set.
descriptor_write_image_info :: proc(
	ctx: ^Context,
	desc: ^DescriptorSet,
	binding: u32,
	image_info: ^vk.DescriptorImageInfo,
	array_element: u32 = 0,
) {
	for i in 0 ..< desc.count {
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = desc.sets[i],
			dstBinding      = binding,
			dstArrayElement = array_element,
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = image_info,
		}
		vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
	}
}

// state names the layout the image will be in when sampled (.Shader_Read for
// color textures, .Depth_Read for shadow maps).
descriptor_write_image_view :: proc(
	ctx: ^Context,
	set: ^DescriptorSet,
	binding: u32,
	img: Image,
	sampler: Sampler,
	state: ImageStateKind = .Shader_Read,
	array_element: u32 = 0,
) {
	image_info := vk.DescriptorImageInfo {
		sampler     = vk.Sampler(sampler),
		imageView   = image_slot(ctx, img).view,
		imageLayout = IMAGE_STATES[state].layout,
	}
	descriptor_write_image_info(ctx, set, binding, &image_info, array_element)
}

// Writes one texture slot of the bindless set (binding 0) in every frame's set. With a mip,
// the slot sees only that level (through its mip view) instead of the whole image.
descriptor_write_bindless_texture :: proc(
	ctx: ^Context,
	desc: ^DescriptorSet,
	array_element: u32,
	img: Image,
	state: ImageStateKind = .Shader_Read,
	mip: Maybe(u32) = nil,
) {
	image_info := vk.DescriptorImageInfo {
		imageView   = image_mip_view(image_slot(ctx, img), mip),
		imageLayout = IMAGE_STATES[state].layout,
	}
	for i in 0 ..< desc.count {
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = desc.sets[i],
			dstBinding      = 0,
			dstArrayElement = array_element,
			descriptorCount = 1,
			descriptorType  = .SAMPLED_IMAGE,
			pImageInfo      = &image_info,
		}
		vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
	}
}

// Writes one sampler slot of the bindless set (binding 1) in every frame's set.
descriptor_write_bindless_sampler :: proc(ctx: ^Context, desc: ^DescriptorSet, array_element: u32, sampler: Sampler) {
	sampler_info := vk.DescriptorImageInfo {
		sampler = vk.Sampler(sampler),
	}
	for i in 0 ..< desc.count {
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = desc.sets[i],
			dstBinding      = 1,
			dstArrayElement = array_element,
			descriptorCount = 1,
			descriptorType  = .SAMPLER,
			pImageInfo      = &sampler_info,
		}
		vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
	}
}

// Bindless storage images for compute: one RWTexture2D array at binding 0, indexed by slot.
// Same update-after-bind flags as the texture set so slots can be rewritten (e.g. after a
// swapchain resize) without reallocating.
descriptor_set_create_bindless_storage :: proc(
	ctx: ^Context,
	image_count: u32,
	count: u32 = MAX_FRAMES_IN_FLIGHT,
) -> DescriptorSet {
	bindings := []vk.DescriptorSetLayoutBinding {
		{binding = 0, descriptorType = .STORAGE_IMAGE, descriptorCount = image_count, stageFlags = {.COMPUTE}},
	}
	binding_flags := []vk.DescriptorBindingFlags {
		DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND, .UPDATE_UNUSED_WHILE_PENDING},
	}
	return descriptor_set_create(
		ctx,
		bindings,
		count,
		binding_flags = binding_flags,
		layout_flags = {.UPDATE_AFTER_BIND_POOL},
		pool_flags = {.UPDATE_AFTER_BIND},
	)
}

// Writes one storage slot in every frame's set. Multi-mip images bind a single mip through
// its mip view; others bind the full view.
descriptor_write_bindless_storage :: proc(
	ctx: ^Context,
	desc: ^DescriptorSet,
	array_element: u32,
	img: Image,
	mip: u32 = 0,
) {
	image_info := vk.DescriptorImageInfo {
		imageView   = image_mip_view(image_slot(ctx, img), mip),
		imageLayout = IMAGE_STATES[.General].layout,
	}
	for i in 0 ..< desc.count {
		write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = desc.sets[i],
			dstBinding      = 0,
			dstArrayElement = array_element,
			descriptorCount = 1,
			descriptorType  = .STORAGE_IMAGE,
			pImageInfo      = &image_info,
		}
		vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
	}
}

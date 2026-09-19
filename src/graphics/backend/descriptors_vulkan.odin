#+build linux

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

// Same shape as descriptor_set_create_sampler_array, but with update-after-bind
// flags so a large slot count can be sparsely written to while in flight -
// the shape needed for the bindless texture system.
//
// Two bindings, not one: the Slang BindlessTextures parameter block declares a
// separate Texture2D array and SamplerState array (needed for the Metal port,
// which can't combine them), so Slang lays it out as binding 0 (sampled images)
// + binding 1 (samplers) rather than a single combined-image-sampler binding.
descriptor_set_create_bindless_array :: proc(
	ctx: ^Context,
	slot_count: u32,
	count: u32 = MAX_FRAMES_IN_FLIGHT,
) -> DescriptorSet {
	bindings := []vk.DescriptorSetLayoutBinding {
		{binding = 0, descriptorType = .SAMPLED_IMAGE, descriptorCount = slot_count, stageFlags = {.FRAGMENT}},
		{binding = 1, descriptorType = .SAMPLER, descriptorCount = slot_count, stageFlags = {.FRAGMENT}},
	}
	binding_flags := []vk.DescriptorBindingFlags {
		DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
		DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
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
	img: ^GpuImage,
	sampler: Sampler,
	state: ImageStateKind = .Shader_Read,
	array_element: u32 = 0,
) {
	image_info := vk.DescriptorImageInfo {
		sampler     = vk.Sampler(sampler),
		imageView   = img.image_view,
		imageLayout = IMAGE_STATES[state].layout,
	}
	descriptor_write_image_info(ctx, set, binding, &image_info, array_element)
}

// Writes one slot of the bindless texture set (see descriptor_set_create_bindless_array):
// the image goes to binding 0 as a SAMPLED_IMAGE, the sampler to binding 1 as a SAMPLER.
descriptor_write_bindless_texture :: proc(
	ctx: ^Context,
	desc: ^DescriptorSet,
	array_element: u32,
	img: ^GpuImage,
	sampler: Sampler,
	state: ImageStateKind = .Shader_Read,
) {
	image_info := vk.DescriptorImageInfo{imageView = img.image_view, imageLayout = IMAGE_STATES[state].layout}
	sampler_info := vk.DescriptorImageInfo{sampler = vk.Sampler(sampler)}

	for i in 0 ..< desc.count {
		writes := [2]vk.WriteDescriptorSet {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = desc.sets[i],
				dstBinding = 0,
				dstArrayElement = array_element,
				descriptorCount = 1,
				descriptorType = .SAMPLED_IMAGE,
				pImageInfo = &image_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = desc.sets[i],
				dstBinding = 1,
				dstArrayElement = array_element,
				descriptorCount = 1,
				descriptorType = .SAMPLER,
				pImageInfo = &sampler_info,
			},
		}
		vk.UpdateDescriptorSets(ctx.device, 2, &writes[0], 0, nil)
	}
}

descriptor_bind_image :: proc(cmd: RenderEncoder, handle: DescriptorSetHandle, binding, target_index: u32) {
	// Vulkan bindings are fixed by the descriptor-set layout and already bound
	// by pipeline_bind; target_index is only needed for Metal's compacted slots.
}

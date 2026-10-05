package backend

import vk "vendor:vulkan"

// The bindless table: one descriptor set, bound at set 0 by every pipeline_bind, that holds
// every resource shaders reach by index. The caller allocates the indices; the backend only
// writes slots. Must match the declarations in shaders/bindless.slang and storage.slang.
//
// Every binding is update-after-bind, so a slot can be written while frames are in flight as
// long as no in-flight frame uses that slot (a fresh slot, or after device_wait_idle).

BindlessDesc :: struct {
	texture_count: u32, // Texture2D[]
	sampler_count: u32, // SamplerState[]
	cube_count:    u32, // TextureCube[]
	storage_count: u32, // RWTexture2D[] (compute only)
}

// Single images with their own sampler, for resources there is exactly one of.
BindlessFixed :: enum {
	Depth_Cube_Array,
	Depth_2D_Array,
}

@(private)
BindlessBinding :: enum u32 {
	Textures         = 0,
	Samplers         = 1,
	Cubes            = 2,
	Storage          = 3,
	Depth_Cube_Array = 4,
	Depth_2D_Array   = 5,
}

@(private)
BindlessTable :: struct {
	desc:            BindlessDesc,
	layout:          vk.DescriptorSetLayout,
	pool:            vk.DescriptorPool,
	set:             vk.DescriptorSet,
	pipeline_layout: vk.PipelineLayout, // shared by every pipeline: this set + the push constant block
}

bindless_init :: proc(ctx: ^Context, desc: BindlessDesc) {
	FLAGS :: vk.DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND, .UPDATE_UNUSED_WHILE_PENDING}
	GRAPHICS_AND_COMPUTE :: vk.ShaderStageFlags{.FRAGMENT, .COMPUTE}

	bindings := [BindlessBinding]vk.DescriptorSetLayoutBinding {
		.Textures = {
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = desc.texture_count,
			stageFlags = GRAPHICS_AND_COMPUTE,
		},
		.Samplers = {
			descriptorType = .SAMPLER,
			descriptorCount = desc.sampler_count,
			stageFlags = GRAPHICS_AND_COMPUTE,
		},
		.Cubes = {descriptorType = .SAMPLED_IMAGE, descriptorCount = desc.cube_count, stageFlags = {.FRAGMENT}},
		.Storage = {descriptorType = .STORAGE_IMAGE, descriptorCount = desc.storage_count, stageFlags = {.COMPUTE}},
		.Depth_Cube_Array = {descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		.Depth_2D_Array = {descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}
	binding_flags: [BindlessBinding]vk.DescriptorBindingFlags
	pool_sizes: [BindlessBinding]vk.DescriptorPoolSize
	for &b, i in bindings {
		b.binding = u32(i)
		binding_flags[i] = FLAGS
		pool_sizes[i] = {
			type            = b.descriptorType,
			descriptorCount = b.descriptorCount,
		}
	}

	flags_info := vk.DescriptorSetLayoutBindingFlagsCreateInfo {
		sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
		bindingCount  = len(BindlessBinding),
		pBindingFlags = &binding_flags[BindlessBinding(0)],
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		pNext        = &flags_info,
		flags        = {.UPDATE_AFTER_BIND_POOL},
		bindingCount = len(BindlessBinding),
		pBindings    = &bindings[BindlessBinding(0)],
	}
	table := &ctx.bindless
	table.desc = desc
	vk_check(vk.CreateDescriptorSetLayout(ctx.device, &layout_info, nil, &table.layout))

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.UPDATE_AFTER_BIND},
		maxSets       = 1,
		poolSizeCount = len(BindlessBinding),
		pPoolSizes    = &pool_sizes[BindlessBinding(0)],
	}
	vk_check(vk.CreateDescriptorPool(ctx.device, &pool_info, nil, &table.pool))

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = table.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &table.layout,
	}
	vk_check(vk.AllocateDescriptorSets(ctx.device, &alloc_info, &table.set))

	push_range := vk.PushConstantRange {
		stageFlags = PUSH_CONSTANT_STAGES,
		size       = PUSH_CONSTANT_SIZE,
	}
	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &table.layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_range,
	}
	vk_check(vk.CreatePipelineLayout(ctx.device, &pipeline_layout_info, nil, &table.pipeline_layout))
}

@(private)
bindless_destroy :: proc(ctx: ^Context) {
	if ctx.bindless.layout == 0 do return
	vk.DestroyPipelineLayout(ctx.device, ctx.bindless.pipeline_layout, nil)
	vk.DestroyDescriptorPool(ctx.device, ctx.bindless.pool, nil)
	vk.DestroyDescriptorSetLayout(ctx.device, ctx.bindless.layout, nil)
	ctx.bindless = {}
}

// Texture2D slot. With a mip, the slot sees only that level instead of the whole image.
bindless_write_texture :: proc(ctx: ^Context, index: u32, img: Image, mip: Maybe(u32) = nil) {
	assert(index < ctx.bindless.desc.texture_count, "bindless_write_texture: index out of range")
	info := vk.DescriptorImageInfo {
		imageView   = image_mip_view(image_slot(ctx, img), mip),
		imageLayout = IMAGE_STATES[.Shader_Read].layout,
	}
	bindless_write(ctx, .Textures, index, .SAMPLED_IMAGE, info)
}

// TextureCube slot. The image must be a cube (its whole view is a cube view).
bindless_write_cube :: proc(ctx: ^Context, index: u32, img: Image) {
	assert(index < ctx.bindless.desc.cube_count, "bindless_write_cube: index out of range")
	slot := image_slot(ctx, img)
	assert(slot.desc.cube, "bindless_write_cube: image is not a cube")
	info := vk.DescriptorImageInfo {
		imageView   = slot.view,
		imageLayout = IMAGE_STATES[.Shader_Read].layout,
	}
	bindless_write(ctx, .Cubes, index, .SAMPLED_IMAGE, info)
}

// RWTexture2D slot. Multi-mip images bind a single mip; others the full view.
bindless_write_storage :: proc(ctx: ^Context, index: u32, img: Image, mip: u32 = 0) {
	assert(index < ctx.bindless.desc.storage_count, "bindless_write_storage: index out of range")
	info := vk.DescriptorImageInfo {
		imageView   = image_mip_view(image_slot(ctx, img), mip),
		imageLayout = IMAGE_STATES[.General].layout,
	}
	bindless_write(ctx, .Storage, index, .STORAGE_IMAGE, info)
}

bindless_write_sampler :: proc(ctx: ^Context, index: u32, sampler: Sampler) {
	assert(index < ctx.bindless.desc.sampler_count, "bindless_write_sampler: index out of range")
	bindless_write(ctx, .Samplers, index, .SAMPLER, {sampler = vk.Sampler(sampler)})
}

// Fixed slots are sampled in the Depth_Read state.
bindless_write_fixed :: proc(ctx: ^Context, fixed: BindlessFixed, img: Image, sampler: Sampler) {
	info := vk.DescriptorImageInfo {
		sampler     = vk.Sampler(sampler),
		imageView   = image_slot(ctx, img).view,
		imageLayout = IMAGE_STATES[.Depth_Read].layout,
	}
	binding: BindlessBinding
	switch fixed {
	case .Depth_Cube_Array:
		binding = .Depth_Cube_Array
	case .Depth_2D_Array:
		binding = .Depth_2D_Array
	}
	bindless_write(ctx, binding, 0, .COMBINED_IMAGE_SAMPLER, info)
}

@(private = "file")
bindless_write :: proc(
	ctx: ^Context,
	binding: BindlessBinding,
	index: u32,
	type: vk.DescriptorType,
	info: vk.DescriptorImageInfo,
) {
	info := info
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = ctx.bindless.set,
		dstBinding      = u32(binding),
		dstArrayElement = index,
		descriptorCount = 1,
		descriptorType  = type,
		pImageInfo      = &info,
	}
	vk.UpdateDescriptorSets(ctx.device, 1, &write, 0, nil)
}

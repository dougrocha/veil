package graphics

import vk "vendor:vulkan"

SHADOW_MAP_SIZE :: 1024

ShadowAtlas :: struct {
	using gpu_image: GpuImage,
	cube_array_view: vk.ImageView,
	face_views:      [MAX_SHADOW_LIGHTS * 6]vk.ImageView,
	sampler:         vk.Sampler,
}

shadow_atlas_create :: proc(ctx: ^VulkanContext, size: u32) -> ShadowAtlas {
	atlas: ShadowAtlas

	atlas.gpu_image = image_create(
		ctx,
		{size, size, 1},
		.D32_SFLOAT,
		{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
		array_layers = MAX_SHADOW_LIGHTS * 6,
		image_flags = {.CUBE_COMPATIBLE},
	)
	atlas.cube_array_view = image_view_create(
		ctx,
		atlas.image,
		.D32_SFLOAT,
		{.DEPTH},
		view_type = .CUBE_ARRAY,
		array_layers = MAX_SHADOW_LIGHTS * 6,
	)

	for i in 0 ..< MAX_SHADOW_LIGHTS * 6 {
		atlas.face_views[i] = image_view_create(
			ctx,
			atlas.image,
			.D32_SFLOAT,
			{.DEPTH},
			base_array_layer = u32(i),
			array_layers = 1,
		)
	}

	sampler_info := vk.SamplerCreateInfo {
		sType         = .SAMPLER_CREATE_INFO,
		magFilter     = .LINEAR,
		minFilter     = .LINEAR,
		mipmapMode    = .LINEAR,
		addressModeU  = .CLAMP_TO_EDGE,
		addressModeV  = .CLAMP_TO_EDGE,
		addressModeW  = .CLAMP_TO_EDGE,
		mipLodBias    = 0.0,
		maxAnisotropy = 1.0,
		minLod        = 0,
		maxLod        = 1.0,
		borderColor   = .FLOAT_OPAQUE_WHITE,
	}
	vk_check(vk.CreateSampler(ctx.device, &sampler_info, nil, &atlas.sampler))

	return atlas
}

shadow_atlas_destroy :: proc(ctx: ^VulkanContext, atlas: ^ShadowAtlas) {
	vk.DestroySampler(ctx.device, atlas.sampler, nil)
	for view in atlas.face_views[:MAX_SHADOW_LIGHTS * 6] {
		vk.DestroyImageView(ctx.device, view, nil)
	}
	vk.DestroyImageView(ctx.device, atlas.cube_array_view, nil)
	destroy_image(ctx, atlas.gpu_image)
}

package graphics

import "backend"

SHADOW_MAP_SIZE :: 2048

SHADOW_MAP_CASCADE_COUNT :: 4

// 2D shadow atlas holds directional lights first, then spot lights.
MAX_SHADOW_2D_SLOTS :: (MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + MAX_SPOT_LIGHTS

ShadowAtlas :: struct {
	using gpu: backend.GpuImage,
	sampler:   backend.Sampler,
}

shadow_atlas_create :: proc(ctx: ^backend.VulkanContext, size: u32, layers: u32, cube: bool) -> ShadowAtlas {
	atlas: ShadowAtlas

	desc := backend.image_desc_default(
		{size, size, 1},
		backend.texture_format_to_vk(.D32_Sfloat),
		{.DEPTH_STENCIL_ATTACHMENT, .SAMPLED},
	)
	desc.array_layers = layers
	if cube {
		desc.image_flags = {.CUBE_COMPATIBLE}
	}
	atlas.gpu = backend.image_create(ctx, desc)

	view_desc := backend.image_view_desc_default(atlas.gpu)
	view_desc.view_type = .CUBE_ARRAY if cube else .D2_ARRAY
	view_desc.array_layers = layers
	atlas.image_view = backend.image_view_create(ctx, atlas.gpu, view_desc)

	sampler_desc := backend.sampler_desc_default()
	sampler_desc.compare_enable = true
	sampler_desc.compare_op = .LESS_OR_EQUAL
	atlas.sampler = backend.sampler_create(ctx, sampler_desc)

	return atlas
}

shadow_atlas_destroy :: proc(ctx: ^backend.VulkanContext, atlas: ^ShadowAtlas) {
	backend.sampler_destroy(ctx, atlas.sampler)
	backend.image_destroy(ctx, atlas.gpu)
}


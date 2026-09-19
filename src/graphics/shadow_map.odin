package graphics

import "backend"

SHADOW_MAP_SIZE :: 2048

ShadowAtlas :: struct {
	using gpu: backend.GpuImage,
	sampler:   backend.Sampler,
}

shadow_atlas_create :: proc(ctx: ^backend.Context, size: u32, layers: u32, cube: bool) -> ShadowAtlas {
	atlas: ShadowAtlas

	desc := backend.image_desc_default(
		backend.extent3d(size, size, 1),
		backend.texture_format_to_backend(.D32_Sfloat),
		{.DepthStencilAttachment, .Sampled},
	)
	desc.array_layers = layers
	if cube {
		backend.image_desc_set_cube_array(&desc)
	}
	atlas.gpu = backend.image_create(ctx, desc)
	backend.image_create_default_view(ctx, &atlas.gpu, cube, layers)

	sampler_desc := backend.sampler_desc_default()
	sampler_desc.compare_enable = true
	sampler_desc.compare_op = .LessOrEqual
	atlas.sampler = backend.sampler_create(ctx, sampler_desc)

	return atlas
}

shadow_atlas_destroy :: proc(ctx: ^backend.Context, atlas: ^ShadowAtlas) {
	backend.sampler_destroy(ctx, atlas.sampler)
	backend.image_destroy(ctx, atlas.gpu)
}

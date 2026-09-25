package graphics

import "backend"

// Cascades and spot maps share the 2D atlas; point cube faces are lower-res since each light
// costs 6 faces. Memory: 8 lights x 6 x 1024^2 x D32 = 192 MiB, 12 slots x 2048^2 x D32 = 192 MiB.
SHADOW_MAP_SIZE :: 2048
POINT_SHADOW_MAP_SIZE :: 1024

// First spot-light layer in the 2D shadow atlas; directional cascades occupy the layers before it.
SPOT_SHADOW_SLOT_BASE :: MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT

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

shadow_atlas_transition :: proc(
	cmd: backend.CommandBuffer,
	atlas: ^ShadowAtlas,
	state: backend.ImageStateKind,
	layer_count: u32,
) {
	backend.image_barrier(cmd, &atlas.gpu, state, backend.ImageAspectFlags{.Depth}, layer_count = layer_count)
}

package graphics

import "backend"
import "core:log"

// Cascades and spot maps share the 2D atlas; point cube faces are lower-res since each light
// costs 6 faces. Memory: 8 lights x 6 x 1024^2 x D32 = 192 MiB, 40 slots x 2048^2 x D32 = 640 MiB.
SHADOW_MAP_SIZE :: 2048
SHADOW_DEPTH_FORMAT :: backend.Format.D32_Sfloat

// First spot-light layer in the 2D shadow atlas; directional cascades occupy the layers before it.
SPOT_SHADOW_SLOT_BASE :: MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT

ShadowAtlas :: struct {
	image:   backend.Image,
	sampler: backend.Sampler,
}

// Both atlases share the depth format, so the filter check is logged once.
shadow_filter_logged: bool

shadow_atlas_create :: proc(ctx: ^backend.Context, size: u32, layers: u32, cube: bool) -> ShadowAtlas {
	atlas: ShadowAtlas

	if !shadow_filter_logged {
		shadow_filter_logged = true
		if backend.format_supports_linear_filter(ctx, SHADOW_DEPTH_FORMAT) {
			log.infof("Shadow depth format %v supports linear filtering; PCF taps are hardware filtered", SHADOW_DEPTH_FORMAT)
		} else {
			log.warnf("Shadow depth format %v lacks linear filtering; PCF degrades to nearest taps", SHADOW_DEPTH_FORMAT)
		}
	}

	desc := backend.image_desc_default(
		backend.extent3d(size, size, 1),
		SHADOW_DEPTH_FORMAT,
		{.DepthStencilAttachment, .Sampled},
	)
	desc.array_layers = layers
	desc.cube = cube
	atlas.image = backend.image_create(ctx, desc)

	sampler_desc := backend.sampler_desc_default()
	sampler_desc.compare_enable = true
	sampler_desc.compare_op = .LessOrEqual
	atlas.sampler = backend.sampler_create(ctx, sampler_desc)

	return atlas
}

shadow_atlas_destroy :: proc(ctx: ^backend.Context, atlas: ^ShadowAtlas) {
	backend.sampler_destroy(ctx, atlas.sampler)
	backend.image_destroy(ctx, atlas.image)
}

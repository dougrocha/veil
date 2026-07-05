package graphics

import "backend"

import vk "vendor:vulkan"

SHADOW_MAP_SIZE :: 2048

ShadowAtlas :: struct {
	using gpu:  GpuImage,
	face_views: [MAX_SHADOW_LIGHTS * 6]vk.ImageView,
	sampler:    vk.Sampler,
}

shadow_atlas_create :: proc(ctx: ^VulkanContext, size: u32) -> ShadowAtlas {
	atlas: ShadowAtlas

	desc := backend.image_desc_default({size, size, 1}, .D32_SFLOAT, {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED})
	desc.array_layers = MAX_SHADOW_LIGHTS * 6
	desc.image_flags = {.CUBE_COMPATIBLE}
	atlas.gpu = backend.image_create(ctx, desc)

	view_desc := backend.image_view_desc_default(atlas.gpu)
	view_desc.view_type = .CUBE_ARRAY
	view_desc.array_layers = MAX_SHADOW_LIGHTS * 6
	atlas.image_view = backend.image_view_create(ctx, atlas.gpu, view_desc)

	for i in 0 ..< MAX_SHADOW_LIGHTS * 6 {
		view_desc := backend.image_view_desc_default(atlas.gpu)
		view_desc.base_array_layer = u32(i)
		view_desc.array_layers = 1
		atlas.face_views[i] = backend.image_view_create(ctx, atlas.gpu, view_desc)
	}

	atlas.sampler = backend.sampler_create(ctx, backend.sampler_desc_default())

	return atlas
}

shadow_atlas_destroy :: proc(ctx: ^VulkanContext, atlas: ^ShadowAtlas) {
	backend.sampler_destroy(ctx, atlas.sampler)
	for view in atlas.face_views[:MAX_SHADOW_LIGHTS * 6] {
		backend.image_view_destroy(ctx, view)
	}
	backend.image_destroy(ctx, atlas.gpu)
}

DirShadowAtlas :: struct {
	using gpu:   GpuImage,
	layer_views: [MAX_SHADOW_LIGHTS]vk.ImageView,
	sampler:     vk.Sampler,
}

dir_shadow_atlas_create :: proc(ctx: ^VulkanContext, size: u32) -> DirShadowAtlas {
	atlas: DirShadowAtlas

	desc := backend.image_desc_default({size, size, 1}, .D32_SFLOAT, {.DEPTH_STENCIL_ATTACHMENT, .SAMPLED})
	desc.array_layers = MAX_SHADOW_LIGHTS
	atlas.gpu = backend.image_create(ctx, desc)

	view_desc := backend.image_view_desc_default(atlas.gpu)
	view_desc.view_type = .D2_ARRAY
	view_desc.array_layers = MAX_SHADOW_LIGHTS
	atlas.image_view = backend.image_view_create(ctx, atlas.gpu, view_desc)

	for i in 0 ..< MAX_SHADOW_LIGHTS {
		view_desc := backend.image_view_desc_default(atlas.gpu)
		view_desc.base_array_layer = u32(i)
		view_desc.array_layers = 1
		atlas.layer_views[i] = backend.image_view_create(ctx, atlas.gpu, view_desc)
	}

	atlas.sampler = backend.sampler_create(ctx, backend.sampler_desc_default())

	return atlas
}

dir_shadow_atlas_destroy :: proc(ctx: ^VulkanContext, atlas: ^DirShadowAtlas) {
	backend.sampler_destroy(ctx, atlas.sampler)
	for view in atlas.layer_views[:MAX_SHADOW_LIGHTS] {
		backend.image_view_destroy(ctx, view)
	}
	backend.image_destroy(ctx, atlas.gpu)
}

package graphics

import "core:log"
import "core:math"
import "core:mem"
import "core:strings"

import "backend"

import stbi "vendor:stb/image"

DEFAULT_TEXTURE_NAME :: "default"
DEFAULT_METALLIC_ROUGHNESS_TEXTURE_NAME :: "default_roughness"
DEFAULT_NORMAL_TEXTURE_NAME :: "default_normal"
DEFAULT_OCCLUSION_TEXTURE_NAME :: "default_occlusion"

MAX_TEXTURES :: 1024

TextureHandle :: Handle(Texture)
INVALID_TEXTURE :: TextureHandle{}

TextureFlags :: distinct bit_set[TextureFlag;u8]
TextureFlag :: enum u8 {
	Transparent,
}

Texture :: struct {
	using gpu:     backend.GpuImage,
	sampler:       backend.Sampler,

	// Texture metadata
	channel_count: u8,
	flags:         TextureFlags,
	filter_min:    TextureFilter,
	filter_mag:    TextureFilter,
	repeat_u:      TextureRepeat,
	repeat_v:      TextureRepeat,
	repeat_w:      TextureRepeat,
}

DefaultTexture :: enum u8 {
	White,
	Flat_Normal,
	Metallic_Roughness,
	Occlusion,
}

TextureSystem :: struct {
	config:      TextureSystemConfig,
	descriptor:  backend.DescriptorSet,

	// storage pool
	textures:           Pool(Texture),
	srgb_texture_map:   map[string]TextureHandle,
	linear_texture_map: map[string]TextureHandle,
	cubemap_map:        map[string]TextureHandle,
	defaults:           [DefaultTexture]TextureHandle,
}

TextureSystemConfig :: struct {
	max_textures_count: u32,
}

texture_system_create :: proc(engine: ^Engine, config: TextureSystemConfig) {
	ts := &engine.texture_system
	ts.config = config
	ts.textures = pool_init(config.max_textures_count, Texture)
	ts.srgb_texture_map = make(map[string]TextureHandle)
	ts.linear_texture_map = make(map[string]TextureHandle)
	ts.cubemap_map = make(map[string]TextureHandle)

	ts.descriptor = backend.descriptor_set_create(
		&engine.vk_ctx,
		{
			{
				binding = 0,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				descriptorCount = config.max_textures_count,
				stageFlags = {.FRAGMENT},
			},
		},
		count = backend.MAX_FRAMES_IN_FLIGHT,
		binding_flags = {backend.DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}},
		layout_flags = {.UPDATE_AFTER_BIND_POOL},
		pool_flags = {.UPDATE_AFTER_BIND},
	)

	texture_create_builtin(engine)
}

texture_destroy :: proc(ctx: ^backend.VulkanContext, t: Texture) {
	backend.sampler_destroy(ctx, t.sampler)
	backend.image_destroy(ctx, t.gpu)
}

texture_system_destroy :: proc(engine: ^Engine) {
	ts := &engine.texture_system
	for &texture, i in ts.textures.values {
		if pool_is_alive(&ts.textures, Index(i)) {
			texture_destroy(&engine.vk_ctx, texture)
		}
	}
	pool_destroy(&ts.textures)
	delete(ts.srgb_texture_map)
	delete(ts.linear_texture_map)
	delete(ts.cubemap_map)
	backend.descriptor_set_destroy(&engine.vk_ctx, &ts.descriptor)
}

texture_system_has_capacity :: proc(ts: ^TextureSystem) -> bool {
	return ts.textures.count < ts.config.max_textures_count
}

// Frees a single texture's GPU resources and removes it from the given cache
// (srgb_texture_map / linear_texture_map / cubemap_map) and the pool. The
// bindless descriptor slot is left stale until reused by a future registration.
texture_unload :: proc(engine: ^Engine, cache: ^map[string]TextureHandle, key: string) {
	ts := &engine.texture_system
	handle, ok := cache[key]
	if !ok {
		return
	}
	texture_destroy(&engine.vk_ctx, pool_get(&ts.textures, handle)^)
	pool_free(&ts.textures, handle)
	delete_key(cache, key)
}

texture_register :: proc(engine: ^Engine, cache: ^map[string]TextureHandle, key: string, t: Texture) -> TextureHandle {
	ts := &engine.texture_system
	handle := pool_alloc(&ts.textures, t)
	cache^[key] = handle
	write_descriptor_texture(&engine.vk_ctx, ts, 0, handle, u32(handle.index))
	return handle
}

texture_create_builtin :: proc(engine: ^Engine) {
	ts := &engine.texture_system
	white: [4]u8 = {0xFF, 0xFF, 0xFF, 0xFF}
	flat_normal: [4]u8 = {128, 128, 0xFF, 0xFF}

	upload_builtin :: proc(
		engine: ^Engine,
		t: Texture,
		pixels: rawptr,
		format: TextureFormat = .Rgba8_Unorm_Srgb,
	) -> TextureHandle {
		ts := &engine.texture_system
		t := t
		texture_upload(&engine.vk_ctx, pixels, &t, format)
		handle := pool_alloc(&ts.textures, t)
		write_descriptor_texture(&engine.vk_ctx, ts, 0, handle, u32(handle.index))
		return handle
	}

	ts.defaults[.White] = upload_builtin(engine, Texture{gpu = {extent = {1, 1, 1}}, channel_count = 4}, &white)
	ts.defaults[.Metallic_Roughness] = upload_builtin(
		engine,
		Texture{gpu = {extent = {1, 1, 1}}, channel_count = 4},
		&white,
	)
	ts.defaults[.Flat_Normal] = upload_builtin(
		engine,
		Texture{gpu = {extent = {1, 1, 1}}, channel_count = 4},
		&flat_normal,
		.Rgba8_Unorm,
	)
	ts.defaults[.Occlusion] = upload_builtin(engine, Texture{gpu = {extent = {1, 1, 1}}, channel_count = 4}, &white)
}

texture_load :: proc {
	texture_load_from_pixels,
	texture_load_from_file,
	texture_load_from_memory,
	texture_load_default,
}

texture_load_default :: #force_inline proc(engine: ^Engine, which: DefaultTexture) -> TextureHandle {
	return engine.texture_system.defaults[which]
}

texture_load_from_file :: proc(engine: ^Engine, path: string, is_srgb: bool = true) -> TextureHandle {
	ts := &engine.texture_system
	cache := &ts.srgb_texture_map if is_srgb else &ts.linear_texture_map
	if handle, ok := cache^[path]; ok {
		return handle
	}

	if !texture_system_has_capacity(ts) {
		log.errorf("Texture system is full (max: %d)", ts.config.max_textures_count)
		return texture_load(engine, DefaultTexture.White)
	}

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	width, height, channels: i32
	pixels := stbi.load(c_path, &width, &height, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil {
		log.errorf("Failed to read image: %s", stbi.failure_reason())
		return engine.texture_system.defaults[.White]
	}

	log.debugf("Loading texture: %s (%dx%d)", path, width, height)

	return texture_load_from_pixels(engine, path, pixels, width, height, channels, is_srgb)
}

texture_load_from_memory :: proc(engine: ^Engine, name: string, data: []byte, is_srgb: bool = true) -> TextureHandle {
	ts := &engine.texture_system
	cache := &ts.srgb_texture_map if is_srgb else &ts.linear_texture_map
	if handle, ok := cache^[name]; ok {
		return handle
	}

	if !texture_system_has_capacity(ts) {
		log.errorf("Texture system is full (max: %d)", ts.config.max_textures_count)
		return texture_load(engine, DefaultTexture.White)
	}

	width, height, channels: i32
	pixels := stbi.load_from_memory(raw_data(data), i32(len(data)), &width, &height, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil {
		log.errorf("Failed to decode image '%s' from memory: %s", name, stbi.failure_reason())
		return texture_load(engine, DefaultTexture.White)
	}

	log.debugf("Loading texture from memory: %s (%dx%d)", name, width, height)

	return texture_load_from_pixels(engine, name, pixels, width, height, channels, is_srgb)
}

// Shared tail of texture_load_from_file/_from_memory: transparency scan, upload, and registration.
texture_load_from_pixels :: proc(
	engine: ^Engine,
	key: string,
	pixels: [^]byte,
	width, height, channels: i32,
	is_srgb: bool,
) -> TextureHandle {
	flags: TextureFlags
	if channels == 4 {
		pixel_count := int(width * height)
		for i in 0 ..< pixel_count {
			if pixels[i * 4 + 3] < 255 {
				flags += {.Transparent}
				break
			}
		}
	}

	texture := Texture {
		gpu = {extent = {u32(width), u32(height), 1}},
		channel_count = 4,
		flags = flags,
	}
	texture_upload(&engine.vk_ctx, pixels, &texture, is_srgb ? .Rgba8_Unorm_Srgb : .Rgba8_Unorm)

	ts := &engine.texture_system
	cache := &ts.srgb_texture_map if is_srgb else &ts.linear_texture_map
	return texture_register(engine, cache, key, texture)
}

// Uploads a texture to the GPU buffer
texture_upload :: proc(
	ctx: ^backend.VulkanContext,
	pixels: rawptr,
	texture: ^Texture,
	format: TextureFormat = .Rgba8_Unorm_Srgb,
) {
	w := texture.extent.width
	h := texture.extent.height
	image_size := w * h * u32(texture.channel_count)

	staging := backend.buffer_create(u8, ctx, int(image_size), .Staging)
	defer backend.buffer_destroy(ctx, staging)
	mem.copy(staging.alloc_info.mapped_data, pixels, int(image_size))

	img_format := backend.texture_format_to_vk(format)
	mip_levels := u32(math.floor(math.log2(f32(max(w, h)))) + 1)

	desc := backend.image_desc_default(
		{w, h, 1},
		img_format,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED, .COLOR_ATTACHMENT},
	)
	desc.mip_levels = mip_levels
	gpu_img := backend.image_create(ctx, desc)

	{
		cmd := backend.immediate_submit(ctx)
		backend.image_barrier(cmd, &gpu_img, .Transfer_Dst, backend.ImageAspectFlags{.COLOR}, level_count = mip_levels)
		backend.copy_buffer_to_image(cmd, staging.buffer, gpu_img.image, w, h)
	}

	backend.generate_mipmaps(ctx, &gpu_img, img_format, w, h, mip_levels)

	texture.gpu = gpu_img
	texture_image_view_create(ctx, texture)
	texture_sampler_create(ctx, texture)
}


texture_load_cubemap :: proc(engine: ^Engine, path: string) -> TextureHandle {
	if handle, ok := engine.texture_system.cubemap_map[path]; ok {
		return handle
	}

	ts := &engine.texture_system
	if !texture_system_has_capacity(ts) {
		log.errorf("Texture system is full (max: %d)", ts.config.max_textures_count)
		return texture_load(engine, DefaultTexture.White)
	}

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	width, height, channels: i32
	pixels := stbi.load(c_path, &width, &height, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil {
		log.errorf("Failed to read cubemap image: %s", stbi.failure_reason())
		return texture_load(engine, DefaultTexture.White)
	}

	log.debugf("Loading cubemap: %s (%dx%d)", path, width, height)

	face_w := u32(width) / 4
	face_h := u32(height) / 3
	face_size := face_w * face_h * 4

	// Vulkan cubemap face order: +X, -X, +Y, -Y, +Z, -Z
	// Horizontal cross layout (col, row):
	face_positions := [6][2]u32 {
		{2, 1}, // +X
		{0, 1}, // -X
		{1, 0}, // +Y
		{1, 2}, // -Y
		{1, 1}, // +Z
		{3, 1}, // -Z
	}

	staging := backend.buffer_create(u8, &engine.vk_ctx, int(face_size * 6), .Staging)
	defer backend.buffer_destroy(&engine.vk_ctx, staging)

	src := ([^]u8)(pixels)
	dst := ([^]u8)(staging.alloc_info.mapped_data)

	for face, i in face_positions {
		col := face[0]
		row := face[1]
		for y in 0 ..< face_h {
			src_offset := ((row * face_h + y) * u32(width) + col * face_w) * 4
			dst_offset := u32(i) * u32(face_size) + y * face_w * 4
			mem.copy(&dst[dst_offset], &src[src_offset], int(face_w * 4))
		}
	}

	desc := backend.image_desc_default(
		{face_w, face_h, 1},
		backend.texture_format_to_vk(.Rgba8_Unorm_Srgb),
		{.TRANSFER_DST, .SAMPLED},
	)
	desc.array_layers = 6
	desc.image_flags = {.CUBE_COMPATIBLE}
	gpu_img := backend.image_create(&engine.vk_ctx, desc)

	{
		cmd := backend.immediate_submit(&engine.vk_ctx)

		backend.image_barrier(cmd, &gpu_img, .Transfer_Dst, backend.ImageAspectFlags{.COLOR}, layer_count = 6)
		backend.copy_buffer_to_cubemap(cmd, staging.buffer, gpu_img.image, face_w, face_h, face_size)
		backend.image_barrier(cmd, &gpu_img, .Shader_Read, backend.ImageAspectFlags{.COLOR}, layer_count = 6)
	}

	t := Texture {
		gpu           = gpu_img,
		channel_count = 4,
	}
	view_desc := backend.image_view_desc_default(t.gpu)
	view_desc.view_type = .CUBE
	view_desc.array_layers = 6
	t.image_view = backend.image_view_create(&engine.vk_ctx, t.gpu, view_desc)
	texture_sampler_create(&engine.vk_ctx, &t)

	return texture_register(engine, &ts.cubemap_map, path, t)
}

texture_image_view_create :: proc(ctx: ^backend.VulkanContext, t: ^Texture) {
	view_desc := backend.image_view_desc_default(t.gpu)
	view_desc.mip_levels = t.mip_levels
	t.image_view = backend.image_view_create(ctx, t.gpu, view_desc)
}

texture_sampler_create :: proc(ctx: ^backend.VulkanContext, t: ^Texture) {
	properties := backend.vk_get_physical_device_properties(ctx)
	desc := backend.sampler_desc_default()
	desc.min_filter = t.filter_min
	desc.mag_filter = t.filter_mag
	desc.address_mode_u = t.repeat_u
	desc.address_mode_v = t.repeat_v
	desc.address_mode_w = t.repeat_w
	desc.anisotropy_enable = true
	desc.max_anisotropy = properties.limits.maxSamplerAnisotropy
	desc.max_lod = backend.LOD_CLAMP_NONE
	desc.border_color = .INT_OPAQUE_BLACK
	t.sampler = backend.sampler_create(ctx, desc)
}


// Writes a texture from the texture system into the descriptor set at the given binding.
// Writes to all sets in the descriptor (all frames).
write_descriptor_texture :: proc(
	ctx: ^backend.VulkanContext,
	ts: ^TextureSystem,
	binding: u32,
	handle: TextureHandle,
	array_element: u32 = 0,
) {
	t := pool_get(&ts.textures, handle)
	backend.descriptor_write_image_view(
		ctx,
		&ts.descriptor,
		binding,
		t.image_view,
		t.sampler,
		array_element = array_element,
	)
}

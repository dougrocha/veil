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

	// Texture metadata
	channel_count: u8,
	flags:         TextureFlags,
}

DefaultTexture :: enum u8 {
	White,
	Flat_Normal,
	Metallic_Roughness,
	Occlusion,
	// 1x1 opaque black cube; texture_load_cubemap's fallback, so cube bindings never get a 2D view.
	Black_Cube,
}

TextureSystem :: struct {
	config:             TextureSystemConfig,
	descriptor:         backend.DescriptorSet,
	// Fixed samplers shared by every bindless texture, indexed by the SAMPLER_* constants.
	samplers:           [BINDLESS_SAMPLER_COUNT]backend.Sampler,

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

	ts.descriptor = backend.descriptor_set_create_bindless_array(
		&engine.vk_ctx,
		config.max_textures_count,
		BINDLESS_SAMPLER_COUNT,
	)
	texture_samplers_create(engine)

	texture_create_builtin(engine)
}

texture_destroy :: proc(ctx: ^backend.Context, t: Texture) {
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
	for sampler in ts.samplers {
		backend.sampler_destroy(&engine.vk_ctx, sampler)
	}
	for cache in ([]^map[string]TextureHandle{&ts.srgb_texture_map, &ts.linear_texture_map, &ts.cubemap_map}) {
		for key in cache {
			delete(key)
		}
		delete(cache^)
	}
	backend.descriptor_set_destroy(&engine.vk_ctx, &ts.descriptor)
}

texture_system_has_capacity :: proc(ts: ^TextureSystem) -> bool {
	// count is the pool's high-water mark; unloading returns slots to free_list instead.
	return ts.textures.count < ts.config.max_textures_count || len(ts.textures.free_list) > 0
}

// Frees a single texture's GPU resources and removes it from the given cache
// (srgb_texture_map / linear_texture_map / cubemap_map) and the pool. The
// bindless descriptor slot is left stale until reused by a future registration.
// Waits for the device to go idle first, since in-flight frames may still sample it.
texture_unload :: proc(engine: ^Engine, cache: ^map[string]TextureHandle, key: string) {
	ts := &engine.texture_system
	handle, ok := cache[key]
	if !ok {
		return
	}
	backend.device_wait_idle(&engine.vk_ctx)
	texture_destroy(&engine.vk_ctx, pool_get(&ts.textures, handle)^)
	pool_free(&ts.textures, handle)
	stored_key, _ := delete_key(cache, key)
	delete(stored_key)
}

// The cache owns a copy of key, so callers may pass temp-allocated strings.
texture_register :: proc(engine: ^Engine, cache: ^map[string]TextureHandle, key: string, t: Texture) -> TextureHandle {
	ts := &engine.texture_system
	handle := pool_alloc(&ts.textures, t)
	cache^[strings.clone(key)] = handle
	write_descriptor_texture(&engine.vk_ctx, ts, handle, u32(handle.index))
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
		write_descriptor_texture(&engine.vk_ctx, ts, handle, u32(handle.index))
		return handle
	}

	ts.defaults[.White] = upload_builtin(
		engine,
		Texture{gpu = {extent = backend.extent3d(1, 1, 1)}, channel_count = 4},
		&white,
	)
	ts.defaults[.Metallic_Roughness] = upload_builtin(
		engine,
		Texture{gpu = {extent = backend.extent3d(1, 1, 1)}, channel_count = 4},
		&white,
	)
	ts.defaults[.Flat_Normal] = upload_builtin(
		engine,
		Texture{gpu = {extent = backend.extent3d(1, 1, 1)}, channel_count = 4},
		&flat_normal,
		.Rgba8_Unorm,
	)
	ts.defaults[.Occlusion] = upload_builtin(
		engine,
		Texture{gpu = {extent = backend.extent3d(1, 1, 1)}, channel_count = 4},
		&white,
	)

	{
		staging := backend.buffer_create(u8, &engine.vk_ctx, 6 * 4, .Staging)
		defer backend.buffer_destroy(&engine.vk_ctx, staging)
		black := ([^][4]u8)(backend.buffer_mapped_ptr(staging))
		for i in 0 ..< 6 do black[i] = {0, 0, 0, 0xFF}

		cube := cubemap_upload(&engine.vk_ctx, staging, 1)
		ts.defaults[.Black_Cube] = pool_alloc(&ts.textures, cube)
		write_descriptor_texture(&engine.vk_ctx, ts, ts.defaults[.Black_Cube], u32(ts.defaults[.Black_Cube].index))
	}
}

texture_load :: proc {
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
	if handle, done := texture_cache_check(ts, cache, path, ts.defaults[.White]); done do return handle

	img, ok := decode_rgba8_file(path)
	if !ok do return ts.defaults[.White]
	defer stbi.image_free(img.pixels)

	log.debugf("Loading texture: %s (%dx%d)", path, img.width, img.height)
	return texture_register_rgba8(engine, cache, path, img, is_srgb)
}

texture_load_from_memory :: proc(engine: ^Engine, name: string, data: []byte, is_srgb: bool = true) -> TextureHandle {
	ts := &engine.texture_system
	cache := &ts.srgb_texture_map if is_srgb else &ts.linear_texture_map
	if handle, done := texture_cache_check(ts, cache, name, ts.defaults[.White]); done do return handle

	img, ok := decode_rgba8_memory(name, data)
	if !ok do return ts.defaults[.White]
	defer stbi.image_free(img.pixels)

	log.debugf("Loading texture from memory: %s (%dx%d)", name, img.width, img.height)
	return texture_register_rgba8(engine, cache, name, img, is_srgb)
}

@(private = "file")
DecodedImage :: struct {
	pixels:                  [^]u8, // always RGBA8; free with stbi.image_free
	width, height, channels: i32, // channels is the source count, before expansion to 4
}

// Returns (handle, true) when the load is already resolved: key is cached, or the pool is full
// and fallback is returned instead.
@(private = "file")
texture_cache_check :: proc(
	ts: ^TextureSystem,
	cache: ^map[string]TextureHandle,
	key: string,
	fallback: TextureHandle,
) -> (
	TextureHandle,
	bool,
) {
	if handle, ok := cache[key]; ok do return handle, true
	if !texture_system_has_capacity(ts) {
		log.errorf("Texture system is full (max: %d), can't load '%s'", ts.config.max_textures_count, key)
		return fallback, true
	}
	return {}, false
}

@(private = "file")
decode_rgba8_file :: proc(path: string) -> (img: DecodedImage, ok: bool) {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	img.pixels = stbi.load(c_path, &img.width, &img.height, &img.channels, 4)
	if img.pixels == nil {
		log.errorf("Failed to read image '%s': %s", path, stbi.failure_reason())
		return {}, false
	}
	return img, true
}

@(private = "file")
decode_rgba8_memory :: proc(name: string, data: []byte) -> (img: DecodedImage, ok: bool) {
	img.pixels = stbi.load_from_memory(raw_data(data), i32(len(data)), &img.width, &img.height, &img.channels, 4)
	if img.pixels == nil {
		log.errorf("Failed to decode image '%s' from memory: %s", name, stbi.failure_reason())
		return {}, false
	}
	return img, true
}

// Shared tail of texture_load_from_file/_from_memory: transparency scan, upload, and registration.
@(private = "file")
texture_register_rgba8 :: proc(
	engine: ^Engine,
	cache: ^map[string]TextureHandle,
	key: string,
	img: DecodedImage,
	is_srgb: bool,
) -> TextureHandle {
	flags: TextureFlags
	if img.channels == 4 {
		for i in 0 ..< int(img.width * img.height) {
			if img.pixels[i * 4 + 3] < 255 {
				flags += {.Transparent}
				break
			}
		}
	}

	texture := Texture {
		gpu = {extent = backend.extent3d(u32(img.width), u32(img.height), 1)},
		channel_count = 4,
		flags = flags,
	}
	texture_upload(&engine.vk_ctx, img.pixels, &texture, is_srgb ? .Rgba8_Unorm_Srgb : .Rgba8_Unorm)
	return texture_register(engine, cache, key, texture)
}

// Uploads a texture to the GPU buffer
texture_upload :: proc(
	ctx: ^backend.Context,
	pixels: rawptr,
	texture: ^Texture,
	format: TextureFormat = .Rgba8_Unorm_Srgb,
) {
	w := u32(texture.extent.width)
	h := u32(texture.extent.height)
	image_size := w * h * u32(texture.channel_count)

	staging := backend.buffer_create(u8, ctx, int(image_size), .Staging)
	defer backend.buffer_destroy(ctx, staging)
	mem.copy(backend.buffer_mapped_ptr(staging), pixels, int(image_size))

	img_format := backend.texture_format_to_backend(format)
	mip_levels := u32(math.floor(math.log2(f32(max(w, h)))) + 1)

	desc := backend.image_desc_default(
		backend.extent3d(w, h, 1),
		img_format,
		{.TransferSrc, .TransferDst, .Sampled, .ColorAttachment},
	)
	desc.mip_levels = mip_levels
	gpu_img := backend.image_create(ctx, desc)

	{
		cmd := backend.immediate_submit(ctx)
		backend.image_barrier(cmd, &gpu_img, .Transfer_Dst, backend.ImageAspectFlags{.Color}, level_count = mip_levels)
		backend.copy_buffer_to_image(cmd, staging.buffer, &gpu_img, w, h)
	}

	backend.generate_mipmaps(ctx, &gpu_img)

	texture.gpu = gpu_img
	texture_image_view_create(ctx, texture)
}


texture_load_cubemap :: proc(engine: ^Engine, path: string) -> TextureHandle {
	ts := &engine.texture_system
	if handle, done := texture_cache_check(ts, &ts.cubemap_map, path, ts.defaults[.Black_Cube]); done do return handle

	img, ok := decode_rgba8_file(path)
	if !ok do return ts.defaults[.Black_Cube]
	defer stbi.image_free(img.pixels)
	width, height, pixels := img.width, img.height, img.pixels

	// Horizontal cross: 4x3 grid of square faces.
	if width <= 0 || width % 4 != 0 || height % 3 != 0 || width / 4 != height / 3 {
		log.errorf("Cubemap '%s' is %dx%d, expected a 4:3 horizontal cross of square faces", path, width, height)
		return ts.defaults[.Black_Cube]
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
	dst := ([^]u8)(backend.buffer_mapped_ptr(staging))

	for face, i in face_positions {
		col := face[0]
		row := face[1]
		for y in 0 ..< face_h {
			src_offset := ((row * face_h + y) * u32(width) + col * face_w) * 4
			dst_offset := u32(i) * u32(face_size) + y * face_w * 4
			mem.copy(&dst[dst_offset], &src[src_offset], int(face_w * 4))
		}
	}

	t := cubemap_upload(&engine.vk_ctx, staging, face_w)
	return texture_register(engine, &ts.cubemap_map, path, t)
}

// Uploads six tightly packed RGBA8 sRGB faces (+X, -X, +Y, -Y, +Z, -Z) of size x size
// texels from staging into a cube image with a cube view.
@(private = "file")
cubemap_upload :: proc(ctx: ^backend.Context, staging: backend.GpuBuffer(u8), size: u32) -> Texture {
	face_size := size * size * 4

	desc := backend.image_desc_default(
		backend.extent3d(size, size, 1),
		backend.texture_format_to_backend(.Rgba8_Unorm_Srgb),
		{.TransferDst, .Sampled},
	)
	desc.array_layers = 6
	backend.image_desc_set_cube_array(&desc)
	gpu_img := backend.image_create(ctx, desc)

	{
		cmd := backend.immediate_submit(ctx)

		backend.image_barrier(cmd, &gpu_img, .Transfer_Dst, backend.ImageAspectFlags{.Color}, layer_count = 6)
		backend.copy_buffer_to_cubemap(cmd, staging.buffer, &gpu_img, size, size, face_size)
		backend.image_barrier(cmd, &gpu_img, .Shader_Read, backend.ImageAspectFlags{.Color}, layer_count = 6)
	}

	t := Texture {
		gpu           = gpu_img,
		channel_count = 4,
	}
	backend.image_view_create_cubemap(ctx, &t.gpu)
	return t
}

texture_image_view_create :: proc(ctx: ^backend.Context, t: ^Texture) {
	backend.image_view_create_default(ctx, &t.gpu)
}

texture_samplers_create :: proc(engine: ^Engine) {
	ts := &engine.texture_system
	ctx := &engine.vk_ctx

	make_sampler :: proc(ctx: ^backend.Context, filter: TextureFilter, repeat: TextureRepeat) -> backend.Sampler {
		desc := backend.sampler_desc_default()
		desc.min_filter = filter
		desc.mag_filter = filter
		desc.address_mode_u = repeat
		desc.address_mode_v = repeat
		desc.address_mode_w = repeat
		desc.anisotropy_enable = filter == .Linear
		desc.max_anisotropy = backend.device_max_anisotropy(ctx)
		desc.max_lod = backend.LOD_CLAMP_NONE
		desc.border_color = .OpaqueBlack
		return backend.sampler_create(ctx, desc)
	}

	ts.samplers[SAMPLER_LINEAR_REPEAT] = make_sampler(ctx, .Linear, .Repeat)
	ts.samplers[SAMPLER_LINEAR_CLAMP] = make_sampler(ctx, .Linear, .Clamp_To_Edge)
	ts.samplers[SAMPLER_NEAREST_CLAMP] = make_sampler(ctx, .Nearest, .Clamp_To_Edge)
	for sampler, i in ts.samplers {
		backend.descriptor_write_bindless_sampler(ctx, &ts.descriptor, u32(i), sampler)
	}
}


// Writes a texture from the texture system into the descriptor set at the given binding.
// Writes to all sets in the descriptor (all frames).
write_descriptor_texture :: proc(
	ctx: ^backend.Context,
	ts: ^TextureSystem,
	handle: TextureHandle,
	array_element: u32 = 0,
) {
	t := pool_get(&ts.textures, handle)
	backend.descriptor_write_bindless_texture(ctx, &ts.descriptor, array_element, &t.gpu)
}

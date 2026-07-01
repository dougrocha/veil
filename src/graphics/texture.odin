package graphics

import "core:log"
import "core:math"
import "core:mem"
import "core:strings"

import vma "shared:odin-vma"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

DEFAULT_TEXTURE_NAME :: "default"
DEFAULT_METALLIC_ROUGHNESS_TEXTURE_NAME :: "default_roughness"
DEFAULT_NORMAL_TEXTURE_NAME :: "default_normal"
DEFAULT_OCCLUSION_TEXTURE_NAME :: "default_occlusion"

MAX_TEXTURES :: 1024

TextureHandle :: Handle(Texture)

INVALID_TEXTURE :: TextureHandle{}

TextureFlags :: distinct bit_set[TextureFlag;u8]
TextureFlag :: enum u8 {
	TRANSPARENT,
}

Texture :: struct {
	using gpu:     GpuImage,
	sampler:       vk.Sampler,

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
	descriptor:  DescriptorSet,

	// storage pool
	textures:    Pool(Texture),
	texture_map: map[string]TextureHandle,
	defaults:    [DefaultTexture]TextureHandle,
}

TextureSystemConfig :: struct {
	max_textures_count: u32,
}

texture_system_create :: proc(engine: ^Engine, config: TextureSystemConfig) {
	ts := &engine.texture_system
	ts.config = config
	ts.textures = pool_init(config.max_textures_count, Texture)
	ts.texture_map = make(map[string]TextureHandle)

	ts.descriptor = create_descriptor_set(
		engine,
		{
			{
				binding = 0,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				descriptorCount = MAX_TEXTURES,
				stageFlags = {.FRAGMENT},
			},
		},
		count = MAX_FRAMES_IN_FLIGHT,
		binding_flags = {vk.DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND}},
		layout_flags = {.UPDATE_AFTER_BIND_POOL},
		pool_flags = {.UPDATE_AFTER_BIND},
	)

	texture_create_builtin(engine)
}

texture_destroy :: proc(ctx: ^VulkanContext, t: Texture) {
	vk.DestroySampler(ctx.device, t.sampler, nil)
	destroy_image(ctx, t.gpu)
}

texture_system_destroy :: proc(engine: ^Engine) {
	ts := &engine.texture_system
	for &texture, i in ts.textures.values {
		if pool_is_alive(&ts.textures, u32(i)) {
			texture_destroy(&engine.vk_ctx, texture)
		}
	}
	pool_destroy(&ts.textures)
	delete(ts.texture_map)
	destroy_descriptor_set(engine, &ts.descriptor)
}

texture_create_builtin :: proc(engine: ^Engine) {
	ts := &engine.texture_system
	white: [4]u8 = {0xFF, 0xFF, 0xFF, 0xFF}
	flat_normal: [4]u8 = {128, 128, 0xFF, 0xFF}

	upload_builtin :: proc(
		engine: ^Engine,
		t: Texture,
		pixels: rawptr,
		format: TextureFormat = .R8G8B8A8_SRGB,
	) -> TextureHandle {
		ts := &engine.texture_system
		t := t
		texture_upload(&engine.vk_ctx, pixels, &t, format)
		handle := pool_alloc(&ts.textures, t)
		write_descriptor_texture(&engine.vk_ctx, ts, 0, handle, handle.index)
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
		.R8G8B8A8_UNORM,
	)
	ts.defaults[.Occlusion] = upload_builtin(engine, Texture{gpu = {extent = {1, 1, 1}}, channel_count = 4}, &white)
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
	if handle, ok := engine.texture_system.texture_map[path]; ok {
		return handle
	}

	ts := &engine.texture_system
	if ts.textures.count >= ts.config.max_textures_count {
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

	flags: TextureFlags
	if channels == 4 {
		pixel_count := int(width * height)
		for i in 0 ..< pixel_count {
			if pixels[i * 4 + 3] < 255 {
				flags += {.TRANSPARENT}
				break
			}
		}
	}

	texture := Texture {
		gpu = {extent = {u32(width), u32(height), 1}},
		channel_count = 4,
		flags = flags,
	}
	texture_upload(&engine.vk_ctx, pixels, &texture, is_srgb ? .R8G8B8A8_SRGB : .R8G8B8A8_UNORM)

	handle := pool_alloc(&ts.textures, texture)
	ts.texture_map[path] = handle
	write_descriptor_texture(&engine.vk_ctx, ts, 0, handle, handle.index)
	return handle
}

texture_load_from_memory :: proc(engine: ^Engine, name: string, data: []byte, is_srgb: bool = true) -> TextureHandle {
	if handle, ok := engine.texture_system.texture_map[name]; ok {
		return handle
	}

	ts := &engine.texture_system
	if ts.textures.count >= ts.config.max_textures_count {
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

	flags: TextureFlags
	if channels == 4 {
		pixel_count := int(width * height)
		for i in 0 ..< pixel_count {
			if pixels[i * 4 + 3] < 255 {
				flags += {.TRANSPARENT}
				break
			}
		}
	}

	texture := Texture {
		gpu = {extent = {u32(width), u32(height), 1}},
		channel_count = 4,
		flags = flags,
	}
	texture_upload(&engine.vk_ctx, pixels, &texture, is_srgb ? .R8G8B8A8_SRGB : .R8G8B8A8_UNORM)

	handle := pool_alloc(&ts.textures, texture)
	ts.texture_map[name] = handle
	write_descriptor_texture(&engine.vk_ctx, ts, 0, handle, handle.index)
	return handle
}

// Uploads a texture to the GPU buffer
texture_upload :: proc(
	ctx: ^VulkanContext,
	pixels: rawptr,
	texture: ^Texture,
	format: TextureFormat = .R8G8B8A8_SRGB,
) {
	w := texture.extent.width
	h := texture.extent.height
	image_size := vk.DeviceSize(w * h * u32(texture.channel_count))

	staging := create_buffer(ctx, image_size, .Staging)
	defer destroy_buffer(ctx, staging)
	mem.copy(staging.alloc_info.mapped_data, pixels, int(image_size))

	img_format := texture_format_to_vk(format)
	mip_levels := u32(math.floor(math.log2(f32(max(w, h)))) + 1)

	gpu_img := image_create(
		ctx,
		{w, h, 1},
		img_format,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED, .COLOR_ATTACHMENT},
		mip_levels = mip_levels,
	)

	cmd := begin_single_time_commands(ctx)
	transition_image_layout(
		cmd,
		gpu_img.image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{},
		{.TRANSFER_WRITE},
		{.TOP_OF_PIPE},
		{.TRANSFER},
		{.COLOR},
		mip_levels,
	)
	copy_buffer_to_image(cmd, staging.buffer, gpu_img.image, w, h)
	end_single_time_commands(ctx, &cmd)

	generate_mipmaps(ctx, gpu_img.image, img_format, w, h, mip_levels)

	texture.gpu = gpu_img
	texture_image_view_create(ctx, texture)
	texture_sampler_create(ctx, texture)
}


texture_load_cubemap :: proc(engine: ^Engine, path: string) -> TextureHandle {
	if handle, ok := engine.texture_system.texture_map[path]; ok {
		return handle
	}

	ts := &engine.texture_system
	if ts.textures.count >= ts.config.max_textures_count {
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
	face_size := vk.DeviceSize(face_w * face_h * 4)

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

	staging := create_buffer(&engine.vk_ctx, face_size * 6, .Staging)
	defer destroy_buffer(&engine.vk_ctx, staging)

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

	gpu_img := image_create(
		&engine.vk_ctx,
		{face_w, face_h, 1},
		TEXTURE_FORMAT,
		{.TRANSFER_DST, .SAMPLED},
		array_layers = 6,
		image_flags = {.CUBE_COMPATIBLE},
	)

	cmd := begin_single_time_commands(&engine.vk_ctx)
	transition_image_layout(
		cmd,
		gpu_img.image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{},
		{.TRANSFER_WRITE},
		{.TOP_OF_PIPE},
		{.TRANSFER},
		{.COLOR},
		layer_count = 6,
	)
	copy_buffer_to_cubemap(cmd, staging.buffer, gpu_img.image, face_w, face_h, face_size)
	transition_image_layout(
		cmd,
		gpu_img.image,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER_WRITE},
		{.SHADER_READ},
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		{.COLOR},
		layer_count = 6,
	)
	end_single_time_commands(&engine.vk_ctx, &cmd)

	t := Texture {
		gpu           = gpu_img,
		channel_count = 4,
	}
	t.image_view = image_view_create(
		&engine.vk_ctx,
		t.image,
		TEXTURE_FORMAT,
		{.COLOR},
		view_type = .CUBE,
		array_layers = 6,
	)
	texture_sampler_create(&engine.vk_ctx, &t)

	handle := pool_alloc(&ts.textures, t)
	ts.texture_map[path] = handle
	write_descriptor_texture(&engine.vk_ctx, &engine.texture_system, 0, handle, handle.index)
	return handle
}

copy_buffer_to_cubemap :: proc(
	cmd: vk.CommandBuffer,
	buffer: vk.Buffer,
	img: vk.Image,
	face_w, face_h: u32,
	face_size: vk.DeviceSize,
) {
	regions: [6]vk.BufferImageCopy2
	for i in 0 ..< 6 {
		regions[i] = vk.BufferImageCopy2 {
			sType = .BUFFER_IMAGE_COPY_2,
			bufferOffset = vk.DeviceSize(i) * face_size,
			imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = u32(i), layerCount = 1},
			imageExtent = {face_w, face_h, 1},
		}
	}

	vk.CmdCopyBufferToImage2(
		cmd,
		&vk.CopyBufferToImageInfo2 {
			sType = .COPY_BUFFER_TO_IMAGE_INFO_2,
			srcBuffer = buffer,
			dstImage = img,
			dstImageLayout = .TRANSFER_DST_OPTIMAL,
			regionCount = 6,
			pRegions = &regions[0],
		},
	)
}

generate_mipmaps :: proc(ctx: ^VulkanContext, image: vk.Image, format: vk.Format, width, height, mip_levels: u32) {
	format_props := get_physical_device_format_properties(ctx, format)

	if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
		log.panicf("Texture image format does not support linear blitting")
	}

	cmd := begin_single_time_commands(ctx)

	mip_width, mip_height := width, height
	for i in 1 ..< mip_levels {
		transition_image_layout(
			cmd,
			image,
			.TRANSFER_DST_OPTIMAL,
			.TRANSFER_SRC_OPTIMAL,
			{.TRANSFER_WRITE},
			{.TRANSFER_READ},
			{.TRANSFER},
			{.TRANSFER},
			{.COLOR},
			1,
			i - 1,
		)

		blit := vk.ImageBlit2 {
			sType = .IMAGE_BLIT_2,
			srcSubresource = {aspectMask = {.COLOR}, mipLevel = i - 1, layerCount = 1},
			srcOffsets = {{0, 0, 0}, {i32(mip_width), i32(mip_height), 1}},
			dstSubresource = {aspectMask = {.COLOR}, mipLevel = i, layerCount = 1},
			dstOffsets = {{0, 0, 0}, {i32(max(mip_width / 2, 1)), i32(max(mip_height / 2, 1)), 1}},
		}
		blit_info := vk.BlitImageInfo2 {
			sType          = .BLIT_IMAGE_INFO_2,
			srcImage       = image,
			srcImageLayout = .TRANSFER_SRC_OPTIMAL,
			dstImage       = image,
			dstImageLayout = .TRANSFER_DST_OPTIMAL,
			regionCount    = 1,
			pRegions       = &blit,
			filter         = .LINEAR,
		}
		vk.CmdBlitImage2(cmd, &blit_info)

		transition_image_layout(
			cmd,
			image,
			.TRANSFER_SRC_OPTIMAL,
			.SHADER_READ_ONLY_OPTIMAL,
			{.TRANSFER_READ},
			{.SHADER_READ},
			{.TRANSFER},
			{.FRAGMENT_SHADER},
			{.COLOR},
			1,
			i - 1,
		)

		if mip_width > 1 do mip_width /= 2
		if mip_height > 1 do mip_height /= 2
	}

	// transition the last mip level which was never used as a blit source
	transition_image_layout(
		cmd,
		image,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER_WRITE},
		{.SHADER_READ},
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		{.COLOR},
		1,
		mip_levels - 1,
	)
	end_single_time_commands(ctx, &cmd)
}

get_max_usable_sample_count :: proc(ctx: ^VulkanContext) -> vk.SampleCountFlags {
	properties := get_physical_device_properties(ctx)

	counts := properties.limits.framebufferColorSampleCounts & properties.limits.framebufferDepthSampleCounts

	if ._64 in counts {return {._64}}
	if ._32 in counts {return {._32}}
	if ._16 in counts {return {._16}}
	if ._8 in counts {return {._8}}
	if ._4 in counts {return {._4}}
	if ._2 in counts {return {._2}}

	return {._1}
}

texture_image_view_create :: proc(ctx: ^VulkanContext, t: ^Texture) {
	t.image_view = image_view_create(ctx, t.image, t.format, {.COLOR}, mip_levels = t.mip_levels)
}

texture_sampler_create :: proc(ctx: ^VulkanContext, t: ^Texture) {
	properties := get_physical_device_properties(ctx)

	sampler_info := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		minFilter               = texture_filter_to_vk(t.filter_min),
		magFilter               = texture_filter_to_vk(t.filter_mag),
		mipmapMode              = .LINEAR,
		addressModeU            = texture_repeat_to_vk(t.repeat_u),
		addressModeV            = texture_repeat_to_vk(t.repeat_v),
		addressModeW            = texture_repeat_to_vk(t.repeat_w),
		mipLodBias              = 0.0,
		anisotropyEnable        = true,
		maxAnisotropy           = properties.limits.maxSamplerAnisotropy,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		minLod                  = 0,
		maxLod                  = vk.LOD_CLAMP_NONE,
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
	}

	vk_check(vk.CreateSampler(ctx.device, &sampler_info, nil, &t.sampler))
}


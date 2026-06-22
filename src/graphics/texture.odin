package graphics

import "core:log"
import "core:math"
import "core:mem"
import "core:strings"

import vma "shared:odin-vma"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

DEFAULT_TEXTURE_NAME :: "default"

MAX_TEXTURES :: 1024

TextureHandle :: Handle(Texture)

INVALID_TEXTURE :: TextureHandle{}

Texture :: struct {
	// vulkan internals
	image:            vk.Image,
	allocation:       vma.Allocation,
	image_view:       vk.ImageView,
	sampler:          vk.Sampler,

	// Texture metadata
	width:            u32,
	height:           u32,
	mip_levels:       u32,
	channel_count:    u8,
	has_transparency: bool,
}

TextureSystem :: struct {
	textures:               Pool(Texture),
	texture_map:            map[string]TextureHandle,
	config:                 TextureSystemConfig,
	default_texture_handle: TextureHandle,
	descriptor:             DescriptorSet,
}

TextureSystemConfig :: struct {
	max_textures_count: u32,
}

create_texture_system :: proc(engine: ^Engine, config: TextureSystemConfig) {
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
			{
				binding = 1,
				descriptorType = .COMBINED_IMAGE_SAMPLER,
				descriptorCount = 1,
				stageFlags = {.FRAGMENT},
			},
		},
		count = MAX_FRAMES_IN_FLIGHT,
		binding_flags = {
			vk.DescriptorBindingFlags{.PARTIALLY_BOUND, .UPDATE_AFTER_BIND},
			{},
		},
		layout_flags = {.UPDATE_AFTER_BIND_POOL},
		pool_flags = {.UPDATE_AFTER_BIND},
	)

	create_builtin_textures(engine)
}

destroy_texture_system :: proc(engine: ^Engine) {
	ts := &engine.texture_system
	for &slot in ts.textures.slots {
		if slot.alive {
			vk.DestroySampler(engine.vk_ctx.device, slot.value.sampler, nil)
			vk.DestroyImageView(engine.vk_ctx.device, slot.value.image_view, nil)
			vma.destroy_image(engine.vk_ctx.vma_allocator, slot.value.image, slot.value.allocation)
		}
	}
	pool_destroy(&ts.textures)
	delete(ts.texture_map)
	destroy_descriptor_set(engine, &ts.descriptor)
}

create_builtin_textures :: proc(engine: ^Engine) {
	white: [4]u8 = {0xFF, 0xFF, 0xFF, 0xFF}
	engine.texture_system.default_texture_handle = upload_texture(engine, DEFAULT_TEXTURE_NAME, &white, 1, 1, 4, false)
}

load_texture :: proc(engine: ^Engine, path: string) -> TextureHandle {
	if handle, ok := engine.texture_system.texture_map[path]; ok {
		return handle
	}

	ts := &engine.texture_system
	if ts.textures.count >= ts.config.max_textures_count {
		log.errorf("Texture system is full (max: %d)", ts.config.max_textures_count)
		return ts.default_texture_handle
	}

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	width, height, channels: i32
	pixels := stbi.load(c_path, &width, &height, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil {
		log.errorf("Failed to read image: %s", stbi.failure_reason())
		return engine.texture_system.default_texture_handle
	}

	return upload_texture(engine, path, pixels, u32(width), u32(height), 4, false)
}

// Uploads a texture to the GPU buffer
upload_texture :: proc(
	engine: ^Engine,
	name: string,
	pixels: rawptr,
	width, height, channels: u32,
	has_transparency: bool,
) -> TextureHandle {
	ts := &engine.texture_system
	image_size := vk.DeviceSize(width * height * channels)

	staging := create_buffer(&engine.vk_ctx, image_size, .Staging)
	defer destroy_buffer(&engine.vk_ctx, staging)
	mem.copy(staging.alloc_info.mapped_data, pixels, int(image_size))

	mip_levels := u32(math.floor(math.log2(f32(max(width, height)))) + 1)
	gpu_img := create_image(
		&engine.vk_ctx,
		{width, height, 1},
		TEXTURE_FORMAT,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		mip_levels = mip_levels,
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
		mip_levels,
	)
	copy_buffer_to_image(cmd, staging.buffer, gpu_img.image, width, height)
	end_single_time_commands(&engine.vk_ctx, &cmd)
	// transitioned to SHADER_READ_ONLY_OPTIMAL while generating mipmaps

	generate_mipmaps(engine, gpu_img.image, TEXTURE_FORMAT, width, height, mip_levels)

	t := Texture {
		image            = gpu_img.image,
		allocation       = gpu_img.alloc,
		mip_levels       = mip_levels,
		width            = width,
		height           = height,
		channel_count    = 4, // set to four cause our TEXTURE_FORMAT is hard coded
		has_transparency = has_transparency,
	}
	create_texture_image_view(&engine.vk_ctx, &t)
	create_texture_sampler(&engine.vk_ctx, &t)

	handle := pool_alloc(&engine.texture_system.textures, t)
	engine.texture_system.texture_map[name] = handle
	write_descriptor_texture(engine, &engine.texture_system.descriptor, 0, handle, handle.index)
	return handle
}

get_default_texture :: proc(engine: ^Engine) -> TextureHandle {
	return engine.texture_system.default_texture_handle
}

load_cubemap_texture :: proc(engine: ^Engine, path: string) -> TextureHandle {
	if handle, ok := engine.texture_system.texture_map[path]; ok {
		return handle
	}

	ts := &engine.texture_system
	if ts.textures.count >= ts.config.max_textures_count {
		log.errorf("Texture system is full (max: %d)", ts.config.max_textures_count)
		return ts.default_texture_handle
	}

	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	width, height, channels: i32
	pixels := stbi.load(c_path, &width, &height, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil {
		log.errorf("Failed to read cubemap image: %s", stbi.failure_reason())
		return ts.default_texture_handle
	}

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

	gpu_img := create_image(
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
		image         = gpu_img.image,
		allocation    = gpu_img.alloc,
		mip_levels    = 1,
		width         = face_w,
		height        = face_h,
		channel_count = 4,
	}
	t.image_view = create_image_view(
		&engine.vk_ctx,
		t.image,
		TEXTURE_FORMAT,
		{.COLOR},
		view_type = .CUBE,
		array_layers = 6,
	)
	create_texture_sampler(&engine.vk_ctx, &t)

	handle := pool_alloc(&ts.textures, t)
	ts.texture_map[path] = handle
	write_descriptor_texture(engine, &engine.texture_system.descriptor, 0, handle, handle.index)
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

generate_mipmaps :: proc(engine: ^Engine, image: vk.Image, format: vk.Format, width, height, mip_levels: u32) {
	format_props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(engine.vk_ctx.physical_device, format, &format_props)

	if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
		log.panicf("Texture image format does not support linear blitting")
	}

	cmd := begin_single_time_commands(&engine.vk_ctx)

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
	end_single_time_commands(&engine.vk_ctx, &cmd)
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

create_texture_image_view :: proc(ctx: ^VulkanContext, t: ^Texture) {
	t.image_view = create_image_view(ctx, t.image, TEXTURE_FORMAT, {.COLOR}, mip_levels = t.mip_levels)
}

create_texture_sampler :: proc(ctx: ^VulkanContext, t: ^Texture) {
	properties := get_physical_device_properties(ctx)

	sampler_info := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = .LINEAR,
		minFilter               = .LINEAR,
		mipmapMode              = .LINEAR,
		addressModeU            = .REPEAT,
		addressModeV            = .REPEAT,
		addressModeW            = .REPEAT,
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


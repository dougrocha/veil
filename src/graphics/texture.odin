package graphics

import "core:log"
import "core:math"
import "core:mem"

import vma "shared:odin-vma"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

TextureHandle :: distinct u64
INVALID_TEXTURE :: TextureHandle(max(u32))

Texture :: struct {
	image:      vk.Image,
	allocation: vma.Allocation,
	image_view: vk.ImageView,
	sampler:    vk.Sampler,
	mip_levels: u32,
}

TextureSystem :: struct {
	textures: [dynamic]Texture,
}

// OLD TEXTURE STUFF BELOW

upload_texture :: proc(engine: ^Engine, pixels: rawptr, width, height: u32) {
	image_size := vk.DeviceSize(width * height * 4)

	staging := create_buffer(engine, image_size, .Staging)
	defer destroy_buffer(engine, staging)
	mem.copy(staging.alloc_info.mapped_data, pixels, int(image_size))

	mip_levels := u32(math.floor(math.log2(f32(max(width, height)))) + 1)
	gpu_img := create_image(
		engine,
		{width, height, 1},
		TEXTURE_FORMAT,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
		mip_levels = mip_levels,
	)


	cmd := begin_single_time_commands(engine)
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
	end_single_time_commands(engine, &cmd)
	// transitioned to SHADER_READ_ONLY_OPTIMAL while generating mipmaps

	generate_mipmaps(engine, &gpu_img.image, TEXTURE_FORMAT, width, height, mip_levels)

	t := Texture {
		image      = gpu_img.image,
		allocation = gpu_img.alloc,
		mip_levels = mip_levels,
	}
	create_texture_image_view(engine, &t)
	create_texture_sampler(engine, &t)
	append(&engine.textures, t)
	update_texture_descriptor(engine, u32(len(engine.textures)) - 1)
}

load_texture :: proc(engine: ^Engine, path: cstring) {
	width, height, channels: i32
	pixels := stbi.load(path, &width, &height, &channels, 4)
	defer stbi.image_free(pixels)
	if pixels == nil {
		log.errorf("Failed to read image: %s", stbi.failure_reason())
		return
	}
	upload_texture(engine, pixels, u32(width), u32(height))
}

create_default_texture :: proc(engine: ^Engine) {
	SIZE :: 16
	pixels: [SIZE * SIZE * 4]u8
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			i := (y * SIZE + x) * 4
			is_magenta := (x + y) % 2 == 0
			pixels[i + 0] = 0xFF if is_magenta else 0x00
			pixels[i + 1] = 0x00
			pixels[i + 2] = 0xFF if is_magenta else 0x00
			pixels[i + 3] = 0xFF
		}
	}
	upload_texture(engine, &pixels, SIZE, SIZE)
}

generate_mipmaps :: proc(engine: ^Engine, image: ^vk.Image, format: vk.Format, width, height, mip_levels: u32) {
	format_props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(engine.physical_device, format, &format_props)

	if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
		log.panicf("Texture image format does not support linear blitting")
	}

	cmd := begin_single_time_commands(engine)

	mip_width, mip_height := width, height
	for i in 1 ..< mip_levels {
		transition_image_layout(
			cmd,
			image^,
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
			srcImage       = image^,
			srcImageLayout = .TRANSFER_SRC_OPTIMAL,
			dstImage       = image^,
			dstImageLayout = .TRANSFER_DST_OPTIMAL,
			regionCount    = 1,
			pRegions       = &blit,
			filter         = .LINEAR,
		}
		vk.CmdBlitImage2(cmd, &blit_info)

		transition_image_layout(
			cmd,
			image^,
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
		image^,
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
	end_single_time_commands(engine, &cmd)
}

get_max_usable_sample_count :: proc(engine: ^Engine) -> vk.SampleCountFlags {
	properties := get_physical_device_properties(engine)

	counts := properties.limits.framebufferColorSampleCounts & properties.limits.framebufferDepthSampleCounts

	if ._64 in counts {return {._64}}
	if ._32 in counts {return {._32}}
	if ._16 in counts {return {._16}}
	if ._8 in counts {return {._8}}
	if ._4 in counts {return {._4}}
	if ._2 in counts {return {._2}}

	return {._1}
}

create_texture_image_view :: proc(engine: ^Engine, t: ^Texture) {
	t.image_view = create_image_view(engine, t.image, TEXTURE_FORMAT, {.COLOR}, mip_levels = t.mip_levels)
}

create_texture_sampler :: proc(engine: ^Engine, t: ^Texture) {
	properties := get_physical_device_properties(engine)

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

	vk_check(vk.CreateSampler(engine.device, &sampler_info, nil, &t.sampler))
}


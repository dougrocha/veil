package graphics

import "core:log"
import "core:math"
import "core:mem"

import vma "shared:odin-vma"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

create_image :: proc(
	engine: ^Engine,
	width, height, mip_levels: u32,
	format: vk.Format,
	tiling: vk.ImageTiling,
	usage: vk.ImageUsageFlags,
) -> (
	vk.Image,
	vma.Allocation,
) {
	image_info := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		format = format,
		extent = {width = width, height = height, depth = 1},
		mipLevels = engine.mip_levels,
		arrayLayers = 1,
		samples = {._1},
		tiling = tiling,
		usage = usage,
		sharingMode = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}

	img: vk.Image
	allocation: vma.Allocation
	vk_check(
		vma.create_image(
			engine.vma_allocator,
			image_info,
			vma.Allocation_Create_Info{usage = .Auto, flags = {}},
			&img,
			&allocation,
			nil,
		),
	)

	return img, allocation
}

create_texture_image :: proc(engine: ^Engine) {
	texture_file :: "textures/viking_room.png"

	width, height, channels: i32
	pixels := stbi.load(texture_file, &width, &height, &channels, 4)
	if pixels == nil {
		log.errorf("Failed to read image: %s", stbi.failure_reason())
		return
	}
	defer stbi.image_free(pixels)

	image_size := vk.DeviceSize(width * height * 4)

	staging_buffer: vk.Buffer
	staging_allocation: vma.Allocation
	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
			vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = image_size, usage = {.TRANSFER_SRC}},
			vma.Allocation_Create_Info{usage = .Auto, flags = {.Host_Access_Sequential_Write}},
			&staging_buffer,
			&staging_allocation,
			nil,
		),
	)
	defer vma.destroy_buffer(engine.vma_allocator, staging_buffer, staging_allocation)

	data: rawptr
	vk_check(vma.map_memory(engine.vma_allocator, staging_allocation, &data))
	mem.copy(data, pixels, int(image_size))
	vma.unmap_memory(engine.vma_allocator, staging_allocation)

	engine.mip_levels = u32(math.floor(math.log2(f32(max(width, height)))) + 1)
	engine.texture_image, engine.texture_image_allocation = create_image(
		engine,
		u32(width),
		u32(height),
		engine.mip_levels,
		TEXTURE_FORMAT,
		.OPTIMAL,
		{.TRANSFER_SRC, .TRANSFER_DST, .SAMPLED},
	)

	cmd := begin_single_time_commands(engine)
	transition_image_layout(
		cmd,
		engine.texture_image,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{},
		{.TRANSFER_WRITE},
		{.TOP_OF_PIPE},
		{.TRANSFER},
		{.COLOR},
		engine.mip_levels,
	)
	copy_buffer_to_image(cmd, staging_buffer, engine.texture_image, u32(width), u32(height))
	end_single_time_commands(engine, &cmd)
	// transitioned to SHADER_READ_ONLY_OPTIMAL while generating mipmaps

	generate_mipmaps(engine, &engine.texture_image, TEXTURE_FORMAT, u32(width), u32(height), engine.mip_levels)
}

generate_mipmaps :: proc(engine: ^Engine, image: ^vk.Image, format: vk.Format, width, height, mip_levels: u32) {
	format_props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(engine.physical_device, format, &format_props)

	if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
		log.panicf("Texture image format does not support linear blitting")
	}

	cmd := begin_single_time_commands(engine)

	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.TRANSFER},
		srcAccessMask = {.TRANSFER_WRITE},
		dstStageMask = {.TRANSFER},
		dstAccessMask = {.TRANSFER_READ},
		oldLayout = .TRANSFER_DST_OPTIMAL,
		newLayout = .TRANSFER_SRC_OPTIMAL,
		image = image^,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}

	mip_width, mip_height := width, height
	for i in 1 ..< mip_levels {
		barrier.subresourceRange.baseMipLevel = i - 1
		barrier.oldLayout = .TRANSFER_DST_OPTIMAL
		barrier.newLayout = .TRANSFER_SRC_OPTIMAL
		barrier.srcStageMask = {.TRANSFER}
		barrier.srcAccessMask = {.TRANSFER_WRITE}
		barrier.dstStageMask = {.TRANSFER}
		barrier.dstAccessMask = {.TRANSFER_READ}

		dep_info := vk.DependencyInfo {
			sType                   = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers    = &barrier,
		}
		vk.CmdPipelineBarrier2(cmd, &dep_info)

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

		barrier.oldLayout = .TRANSFER_SRC_OPTIMAL
		barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
		barrier.srcStageMask = {.TRANSFER}
		barrier.srcAccessMask = {.TRANSFER_READ}
		barrier.dstStageMask = {.FRAGMENT_SHADER}
		barrier.dstAccessMask = {.SHADER_READ}

		dep_info = vk.DependencyInfo {
			sType                   = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers    = &barrier,
		}
		vk.CmdPipelineBarrier2(cmd, &dep_info)

		if mip_width > 1 do mip_width /= 2
		if mip_height > 1 do mip_height /= 2
	}

	barrier.subresourceRange.baseMipLevel = mip_levels - 1
	barrier.oldLayout = .TRANSFER_DST_OPTIMAL
	barrier.newLayout = .SHADER_READ_ONLY_OPTIMAL
	barrier.srcAccessMask = {.TRANSFER_WRITE}
	barrier.dstAccessMask = {.SHADER_READ}
	barrier.dstStageMask = {.FRAGMENT_SHADER}

	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)

	end_single_time_commands(engine, &cmd)
}

create_texture_image_view :: proc(engine: ^Engine) {
	engine.texture_image_view = create_image_view(
		engine,
		engine.texture_image,
		TEXTURE_FORMAT,
		{.COLOR},
		engine.mip_levels,
	)
}

create_texture_sampler :: proc(engine: ^Engine) {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(engine.physical_device, &properties)

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

	vk_check(vk.CreateSampler(engine.device, &sampler_info, nil, &engine.texture_sampler))
}


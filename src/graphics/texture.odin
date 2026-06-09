package graphics

import "core:log"
import "core:mem"

import vma "shared:odin-vma"
import stbi "vendor:stb/image"
import vk "vendor:vulkan"

create_image :: proc(
	engine: ^Engine,
	width, height: u32,
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
		mipLevels = 1,
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

	engine.texture_image, engine.texture_image_allocation = create_image(
		engine,
		u32(width),
		u32(height),
		TEXTURE_FORMAT,
		.OPTIMAL,
		{.TRANSFER_DST, .SAMPLED},
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
	)
	copy_buffer_to_image(cmd, staging_buffer, engine.texture_image, u32(width), u32(height))
	transition_image_layout(
		cmd,
		engine.texture_image,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER_WRITE},
		{.SHADER_READ},
		{.TRANSFER},
		{.FRAGMENT_SHADER},
		{.COLOR},
	)

	end_single_time_commands(engine, &cmd)
}

create_texture_image_view :: proc(engine: ^Engine) {
	create_image_view(engine, engine.texture_image, TEXTURE_FORMAT, {.COLOR}, &engine.texture_image_view)
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
		anisotropyEnable        = true,
		maxAnisotropy           = properties.limits.maxSamplerAnisotropy,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
	}

	vk_check(vk.CreateSampler(engine.device, &sampler_info, nil, &engine.texture_sampler))
}


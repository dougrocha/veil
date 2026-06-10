package graphics

import vma "shared:odin-vma"
import vk "vendor:vulkan"

create_image :: proc(
	engine: ^Engine,
	width, height, mip_levels: u32,
	samples: vk.SampleCountFlags,
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
		mipLevels = mip_levels,
		arrayLayers = 1,
		samples = samples,
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

create_image_view :: proc(
	engine: ^Engine,
	img: vk.Image,
	format: vk.Format,
	aspect: vk.ImageAspectFlags,
	mip_levels: u32 = 1,
) -> vk.ImageView {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = img,
		viewType = .D2,
		format = format,
		subresourceRange = {
			aspectMask = aspect,
			baseMipLevel = 0,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	view: vk.ImageView
	vk_check(vk.CreateImageView(engine.device, &info, nil, &view))
	return view
}

transition_image_layout :: proc(
	cmd: vk.CommandBuffer,
	img: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
	src_access: vk.AccessFlags2,
	dst_access: vk.AccessFlags2,
	src_stage: vk.PipelineStageFlags2,
	dst_stage: vk.PipelineStageFlags2,
	aspect: vk.ImageAspectFlags,
	mip_levels: u32 = 1,
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = img,
		subresourceRange = {aspectMask = aspect, levelCount = mip_levels, layerCount = 1},
	}

	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)
}

copy_buffer_to_image :: proc(cmd: vk.CommandBuffer, buffer: vk.Buffer, img: vk.Image, width, height: u32) {
	region := vk.BufferImageCopy2 {
		sType = .BUFFER_IMAGE_COPY_2,
		bufferOffset = 0,
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		imageOffset = {0, 0, 0},
		imageExtent = {width, height, 1},
	}

	vk.CmdCopyBufferToImage2(
		cmd,
		&vk.CopyBufferToImageInfo2 {
			sType = .COPY_BUFFER_TO_IMAGE_INFO_2,
			srcBuffer = buffer,
			dstImage = img,
			dstImageLayout = .TRANSFER_DST_OPTIMAL,
			regionCount = 1,
			pRegions = &region,
		},
	)
}


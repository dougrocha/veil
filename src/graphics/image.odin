package graphics

import vma "shared:odin-vma"
import vk "vendor:vulkan"

GpuImage :: struct {
	image:        vk.Image,
	image_view:   vk.ImageView,
	alloc:        vma.Allocation,
	alloc_info:   vma.Allocation_Info,
	extent:       vk.Extent3D,
	format:       vk.Format,
	mip_levels:   u32,
	array_layers: u32,
	layout:       vk.ImageLayout,
	usage:        vk.ImageUsageFlags,
}

create_image :: proc(
	engine: ^Engine,
	extent: vk.Extent3D,
	format: vk.Format,
	image_usage_flags: vk.ImageUsageFlags,
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	samples: vk.SampleCountFlags = {._1},
	tiling: vk.ImageTiling = .OPTIMAL,
	image_type: vk.ImageType = .D2,
	image_flags: vk.ImageCreateFlags = {},
	alloc_flags: vma.Allocation_Create_Flags = {},
) -> GpuImage {
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = image_type,
		format        = format,
		extent        = extent,
		mipLevels     = mip_levels,
		arrayLayers   = array_layers,
		samples       = samples,
		tiling        = tiling,
		usage         = image_usage_flags,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
		flags         = image_flags,
	}

	gpu_img := GpuImage {
		extent       = extent,
		format       = format,
		mip_levels   = mip_levels,
		array_layers = array_layers,
		layout       = .UNDEFINED,
		usage        = image_usage_flags,
	}

	vk_check(
		vma.create_image(
			engine.vma_allocator,
			image_info,
			vma.Allocation_Create_Info{usage = .Auto, required_flags = {.DEVICE_LOCAL}, flags = alloc_flags},
			&gpu_img.image,
			&gpu_img.alloc,
			&gpu_img.alloc_info,
		),
	)

	return gpu_img
}

destroy_image :: proc(engine: ^Engine, img: GpuImage) {
	vk.DestroyImageView(engine.device, img.image_view, nil)
	vma.destroy_image(engine.vma_allocator, img.image, img.alloc)
}

create_image_view :: proc(
	engine: ^Engine,
	img: vk.Image,
	format: vk.Format,
	aspect: vk.ImageAspectFlags,
	view_type: vk.ImageViewType = .D2,
	mip_levels: u32 = 1,
	array_layers: u32 = 1,
	base_mip_level: u32 = 0,
	base_array_layer: u32 = 0,
) -> vk.ImageView {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = img,
		viewType = view_type,
		format = format,
		subresourceRange = {
			aspectMask = aspect,
			baseMipLevel = base_mip_level,
			levelCount = mip_levels,
			baseArrayLayer = base_array_layer,
			layerCount = array_layers,
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
	base_mip_level: u32 = 0,
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
		subresourceRange = {
			aspectMask = aspect,
			baseMipLevel = base_mip_level,
			levelCount = mip_levels,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)
}

copy_image_to_image :: proc(cmd: vk.CommandBuffer, src, dst: vk.Image, src_extent, dst_extent: vk.Extent2D) {
	blit_region := vk.ImageBlit2 {
		sType = .IMAGE_BLIT_2,
		srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
	}
	blit_region.srcOffsets[1] = {i32(src_extent.width), i32(src_extent.height), 1}
	blit_region.dstOffsets[1] = {i32(dst_extent.width), i32(dst_extent.height), 1}

	vk.CmdBlitImage2(
		cmd,
		&vk.BlitImageInfo2 {
			sType = .BLIT_IMAGE_INFO_2,
			srcImage = src,
			srcImageLayout = .TRANSFER_SRC_OPTIMAL,
			dstImage = dst,
			dstImageLayout = .TRANSFER_DST_OPTIMAL,
			filter = .NEAREST,
			regionCount = 1,
			pRegions = &blit_region,
		},
	)
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


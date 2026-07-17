package backend

import "core:log"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

GpuImage :: struct {
	image:        vk.Image,
	image_view:   vk.ImageView,
	layer_views:  []vk.ImageView, // one per array layer; only for multi-layer attachment images
	alloc:        vma.Allocation,
	alloc_info:   vma.Allocation_Info,
	extent:       vk.Extent3D,
	format:       vk.Format,
	mip_levels:   u32,
	array_layers: u32,
	layout:       vk.ImageLayout,
	usage:        vk.ImageUsageFlags,
}

ImageDesc :: struct {
	extent:            vk.Extent3D,
	format:            vk.Format,
	image_usage_flags: vk.ImageUsageFlags,
	mip_levels:        u32,
	array_layers:      u32,
	samples:           vk.SampleCountFlags,
	tiling:            vk.ImageTiling,
	image_type:        vk.ImageType,
	image_flags:       vk.ImageCreateFlags,
	alloc_flags:       vma.Allocation_Create_Flags,
}

image_desc_default :: proc(
	extent: vk.Extent3D,
	format: vk.Format,
	image_usage_flags: vk.ImageUsageFlags,
) -> ImageDesc {
	return ImageDesc {
		extent = extent,
		format = format,
		image_usage_flags = image_usage_flags,
		mip_levels = 1,
		array_layers = 1,
		samples = {._1},
		tiling = .OPTIMAL,
		image_type = .D2,
		image_flags = {},
		alloc_flags = {},
	}
}

image_create :: proc(ctx: ^VulkanContext, desc: ImageDesc) -> GpuImage {
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = desc.image_type,
		format        = desc.format,
		extent        = desc.extent,
		mipLevels     = desc.mip_levels,
		arrayLayers   = desc.array_layers,
		samples       = desc.samples,
		tiling        = desc.tiling,
		usage         = desc.image_usage_flags,
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
		flags         = desc.image_flags,
	}

	gpu_img := GpuImage {
		extent       = desc.extent,
		format       = desc.format,
		mip_levels   = desc.mip_levels,
		array_layers = desc.array_layers,
		layout       = .UNDEFINED,
		usage        = desc.image_usage_flags,
	}

	vk_check(
		vma.create_image(
			ctx.vma_allocator,
			image_info,
			vma.Allocation_Create_Info{usage = .Auto, required_flags = {.DEVICE_LOCAL}, flags = desc.alloc_flags},
			&gpu_img.image,
			&gpu_img.alloc,
			&gpu_img.alloc_info,
		),
	)

	if desc.array_layers > 1 && desc.image_usage_flags & {.COLOR_ATTACHMENT, .DEPTH_STENCIL_ATTACHMENT} != {} {
		gpu_img.layer_views = make([]vk.ImageView, desc.array_layers)
		for i in 0 ..< desc.array_layers {
			view_desc := image_view_desc_default(gpu_img)
			view_desc.base_array_layer = i
			view_desc.array_layers = 1
			view_desc.mip_levels = 1
			gpu_img.layer_views[i] = image_view_create(ctx, gpu_img, view_desc)
		}
	}

	return gpu_img
}

image_destroy :: proc(ctx: ^VulkanContext, img: GpuImage) {
	image_view_destroy(ctx, img.image_view)
	for view in img.layer_views {
		image_view_destroy(ctx, view)
	}
	delete(img.layer_views)
	vma.destroy_image(ctx.vma_allocator, img.image, img.alloc)
}

// View to render into one (layer, mip) of an image. Falls back to the full
// view for single-layer images.
image_attachment_view :: proc(img: ^GpuImage, layer: u32, mip: u32 = 0) -> vk.ImageView {
	assert(mip == 0, "mip attachment views not implemented yet")
	if len(img.layer_views) == 0 {
		assert(layer == 0, "image has no layer views")
		return img.image_view
	}
	return img.layer_views[layer]
}

ImageViewDesc :: struct {
	view_type:        vk.ImageViewType,
	mip_levels:       u32,
	array_layers:     u32,
	base_mip_level:   u32,
	base_array_layer: u32,
}

image_view_desc_default :: proc(img: GpuImage) -> ImageViewDesc {
	return ImageViewDesc{view_type = .D2, mip_levels = img.mip_levels, array_layers = img.array_layers}
}

image_view_create :: proc(ctx: ^VulkanContext, img: GpuImage, desc: ImageViewDesc) -> vk.ImageView {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = img.image,
		viewType = desc.view_type,
		format = img.format,
		subresourceRange = {
			aspectMask = format_aspect_mask(img.format),
			baseMipLevel = desc.base_mip_level,
			levelCount = desc.mip_levels,
			baseArrayLayer = desc.base_array_layer,
			layerCount = desc.array_layers,
		},
	}
	view: vk.ImageView
	vk_check(vk.CreateImageView(ctx.device, &info, nil, &view))
	return view
}

image_view_destroy :: proc(ctx: ^VulkanContext, view: vk.ImageView) {
	vk.DestroyImageView(ctx.device, view, nil)
}

ImageState :: struct {
	layout: vk.ImageLayout,
	access: vk.AccessFlags2,
	stage:  vk.PipelineStageFlags2,
}

IMAGE_STATES := [ImageStateKind]ImageState {
	.Undefined    = {.UNDEFINED, {}, {}},
	.Depth_Write  = {
		.DEPTH_ATTACHMENT_OPTIMAL,
		{.DEPTH_STENCIL_ATTACHMENT_WRITE},
		{.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
	},
	.Depth_Read   = {.DEPTH_STENCIL_READ_ONLY_OPTIMAL, {.SHADER_READ}, {.FRAGMENT_SHADER}},
	.Color_Write  = {.COLOR_ATTACHMENT_OPTIMAL, {.COLOR_ATTACHMENT_WRITE}, {.COLOR_ATTACHMENT_OUTPUT}},
	.Transfer_Src = {.TRANSFER_SRC_OPTIMAL, {.TRANSFER_READ}, {.TRANSFER}},
	.Transfer_Dst = {.TRANSFER_DST_OPTIMAL, {.TRANSFER_WRITE}, {.TRANSFER}},
	.Present      = {.PRESENT_SRC_KHR, {}, {}},
	.Shader_Read  = {.SHADER_READ_ONLY_OPTIMAL, {.SHADER_READ}, {.FRAGMENT_SHADER}},
}

// all cases we have for transitioning image state
ImageStateKind :: enum {
	Undefined,
	Depth_Write,
	Depth_Read,
	Color_Write,
	Transfer_Src,
	Transfer_Dst,
	Present,
	Shader_Read,
}

image_barrier :: proc(
	cmd: CommandBuffer,
	img: vk.Image,
	src, dst: ImageStateKind,
	aspect_mask: vk.ImageAspectFlags,
	base_mip_level: u32 = 0,
	level_count: u32 = 1,
	layer_count: u32 = 1,
) {
	src := IMAGE_STATES[src]
	dst := IMAGE_STATES[dst]

	barrier := vk.ImageMemoryBarrier2 {
		sType               = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask        = src.stage,
		srcAccessMask       = src.access,
		oldLayout           = src.layout,
		dstStageMask        = dst.stage,
		dstAccessMask       = dst.access,
		newLayout           = dst.layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image               = img,
		subresourceRange    = {aspect_mask, base_mip_level, level_count, 0, layer_count},
	}
	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(vk.CommandBuffer(cmd), &dep_info)
}

// image helpers

generate_mipmaps :: proc(ctx: ^VulkanContext, image: vk.Image, format: vk.Format, width, height, mip_levels: u32) {
	format_props := vk_get_physical_device_format_properties(ctx, format)

	if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
		log.panicf("Texture image format does not support linear blitting")
	}

	{
		cmd := immediate_submit(ctx)

		mip_width, mip_height := width, height
		for i in 1 ..< mip_levels {
			image_barrier(cmd, image, .Transfer_Dst, .Transfer_Src, {.COLOR}, level_count = 1, base_mip_level = i - 1)

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
			vk.CmdBlitImage2(vk.CommandBuffer(cmd), &blit_info)

			image_barrier(cmd, image, .Transfer_Src, .Shader_Read, {.COLOR}, level_count = 1, base_mip_level = i - 1)

			if mip_width > 1 do mip_width /= 2
			if mip_height > 1 do mip_height /= 2
		}

		image_barrier(
			cmd,
			image,
			.Transfer_Dst,
			.Shader_Read,
			{.COLOR},
			level_count = 1,
			base_mip_level = mip_levels - 1,
		)
	}
}

copy_image_to_image :: proc(cmd: CommandBuffer, src, dst: vk.Image, src_extent, dst_extent: vk.Extent2D) {
	blit_region := vk.ImageBlit2 {
		sType = .IMAGE_BLIT_2,
		srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
	}
	blit_region.srcOffsets[1] = {i32(src_extent.width), i32(src_extent.height), 1}
	blit_region.dstOffsets[1] = {i32(dst_extent.width), i32(dst_extent.height), 1}

	vk.CmdBlitImage2(
		vk.CommandBuffer(cmd),
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

copy_buffer_to_image :: proc(cmd: CommandBuffer, buffer: vk.Buffer, img: vk.Image, width, height: u32) {
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
		vk.CommandBuffer(cmd),
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

copy_buffer_to_cubemap :: proc(
	cmd: CommandBuffer,
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
		vk.CommandBuffer(cmd),
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

LOD_CLAMP_NONE :: vk.LOD_CLAMP_NONE

SamplerDesc :: struct {
	min_filter, mag_filter:   TextureFilter,
	mipmap_mode:              vk.SamplerMipmapMode,
	address_mode_u:           TextureRepeat,
	address_mode_v:           TextureRepeat,
	address_mode_w:           TextureRepeat,
	mip_lod_bias:             f32,
	anisotropy_enable:        bool,
	max_anisotropy:           f32,
	compare_enable:           bool,
	compare_op:               vk.CompareOp,
	min_lod, max_lod:         f32,
	border_color:             vk.BorderColor,
	unnormalized_coordinates: bool,
}

sampler_desc_default :: proc() -> SamplerDesc {
	return SamplerDesc {
		min_filter = .Linear,
		mag_filter = .Linear,
		mipmap_mode = .LINEAR,
		address_mode_u = .Clamp_To_Edge,
		address_mode_v = .Clamp_To_Edge,
		address_mode_w = .Clamp_To_Edge,
		max_anisotropy = 1.0,
		compare_op = .ALWAYS,
		max_lod = 1.0,
		border_color = .FLOAT_OPAQUE_WHITE,
	}
}

sampler_create :: proc(ctx: ^VulkanContext, desc: SamplerDesc) -> Sampler {
	info := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		minFilter               = texture_filter_to_vk(desc.min_filter),
		magFilter               = texture_filter_to_vk(desc.mag_filter),
		mipmapMode              = desc.mipmap_mode,
		addressModeU            = texture_repeat_to_vk(desc.address_mode_u),
		addressModeV            = texture_repeat_to_vk(desc.address_mode_v),
		addressModeW            = texture_repeat_to_vk(desc.address_mode_w),
		mipLodBias              = desc.mip_lod_bias,
		anisotropyEnable        = b32(desc.anisotropy_enable),
		maxAnisotropy           = desc.max_anisotropy,
		compareEnable           = b32(desc.compare_enable),
		compareOp               = desc.compare_op,
		minLod                  = desc.min_lod,
		maxLod                  = desc.max_lod,
		borderColor             = desc.border_color,
		unnormalizedCoordinates = b32(desc.unnormalized_coordinates),
	}
	sampler: vk.Sampler
	vk_check(vk.CreateSampler(ctx.device, &info, nil, &sampler))
	return Sampler(sampler)
}

sampler_destroy :: proc(ctx: ^VulkanContext, sampler: Sampler) {
	vk.DestroySampler(ctx.device, vk.Sampler(sampler), nil)
}

package backend

import "core:log"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

import "../../handles"

extent3d :: proc(width, height, depth: u32) -> Extent3D {
	return {width, height, depth}
}

image_aspect_to_vk :: proc(flags: ImageAspectFlags) -> vk.ImageAspectFlags {
	vk_flags: vk.ImageAspectFlags
	if .Color in flags do vk_flags += {.COLOR}
	if .Depth in flags do vk_flags += {.DEPTH}
	if .Stencil in flags do vk_flags += {.STENCIL}
	return vk_flags
}

// Handle to a backend-owned image. The zero value means "no image". Stale handles (to a
// destroyed image) assert on use.
Image :: handles.Handle(ImageSlot)

MAX_IMAGES :: 2048

// Everything Vulkan about an image. Lives in ctx.images; only the backend sees it.
@(private)
ImageSlot :: struct {
	desc:        ImageDesc,
	image:       vk.Image,
	view:        vk.ImageView, // whole image: D2, D2_ARRAY, CUBE or CUBE_ARRAY from desc
	layer_views: []vk.ImageView, // one per array layer; only for multi-layer attachment images
	mip_views:   []vk.ImageView, // one per mip level; only for multi-mip images
	alloc:       vma.Allocation,
	layout:      []vk.ImageLayout, // one per (mip, layer); index with image_layout_index
}

image_usage_to_vk :: proc(usage: ImageUsageFlags) -> vk.ImageUsageFlags {
	flags: vk.ImageUsageFlags
	if .TransferSrc in usage do flags += {.TRANSFER_SRC}
	if .TransferDst in usage do flags += {.TRANSFER_DST}
	if .Sampled in usage do flags += {.SAMPLED}
	if .Storage in usage do flags += {.STORAGE}
	if .ColorAttachment in usage do flags += {.COLOR_ATTACHMENT}
	if .DepthStencilAttachment in usage do flags += {.DEPTH_STENCIL_ATTACHMENT}
	if .Transient in usage do flags += {.TRANSIENT_ATTACHMENT}
	return flags
}

@(private)
image_layout_index :: proc(slot: ^ImageSlot, mip, layer: u32) -> u32 {
	return mip * slot.desc.array_layers + layer
}

// Backend-neutral description of an image; image_create takes it as-is and image_desc
// returns it unchanged.
ImageDesc :: struct {
	extent:       Extent3D,
	format:       Format,
	usage:        ImageUsageFlags,
	mip_levels:   u32,
	array_layers: u32,
	samples:      u32,
	cube:         bool, // layers are cube faces (array_layers a multiple of 6)
}

image_desc_default :: proc(extent: Extent3D, format: Format, usage: ImageUsageFlags) -> ImageDesc {
	return ImageDesc{extent = extent, format = format, usage = usage, mip_levels = 1, array_layers = 1, samples = 1}
}

images_init :: proc(ctx: ^Context) {
	ctx.images = handles.pool_init(MAX_IMAGES, ImageSlot)
}

images_destroy :: proc(ctx: ^Context) {
	assert(handles.pool_live_count(&ctx.images) == 0, "images_destroy: images still alive")
	handles.pool_destroy(&ctx.images)
}

// True while the image is alive: false for the zero handle and after image_destroy.
image_is_valid :: proc(ctx: ^Context, img: Image) -> bool {
	return handles.pool_is_valid(&ctx.images, img)
}

@(private)
image_slot :: proc(ctx: ^Context, img: Image) -> ^ImageSlot {
	return handles.pool_get(&ctx.images, img)
}

// The description the image was created with.
image_desc :: proc(ctx: ^Context, img: Image) -> ImageDesc {
	return image_slot(ctx, img).desc
}

// Creates the image, its whole-image view, and per-layer (attachments) and per-mip (storage)
// views.
image_create :: proc(ctx: ^Context, desc: ImageDesc) -> Image {
	image_info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format_to_vk(desc.format),
		extent        = {desc.extent.width, desc.extent.height, desc.extent.depth},
		mipLevels     = desc.mip_levels,
		arrayLayers   = desc.array_layers,
		samples       = samples_to_vk(desc.samples),
		tiling        = .OPTIMAL,
		usage         = image_usage_to_vk(desc.usage),
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
		flags         = {.CUBE_COMPATIBLE} if desc.cube else {},
	}

	slot := ImageSlot {
		desc = desc,
	}
	slot.layout = make([]vk.ImageLayout, desc.mip_levels * desc.array_layers)
	for &l in slot.layout do l = .UNDEFINED

	vk_check(
		vma.create_image(
			ctx.vma_allocator,
			image_info,
			vma.Allocation_Create_Info{usage = .Auto, required_flags = {.DEVICE_LOCAL}},
			&slot.image,
			&slot.alloc,
			nil,
		),
	)

	// Transfer-only images (e.g. readback staging) can't have views.
	VIEW_USAGE :: ImageUsageFlags{.Sampled, .Storage, .ColorAttachment, .DepthStencilAttachment}
	if desc.usage & VIEW_USAGE != {} {
		view_type: vk.ImageViewType = .D2
		if desc.cube {
			view_type = .CUBE if desc.array_layers == 6 else .CUBE_ARRAY
		} else if desc.array_layers > 1 {
			view_type = .D2_ARRAY
		}
		slot.view = image_view_create(ctx, &slot, view_type, 0, desc.mip_levels, 0, desc.array_layers)
	}

	if desc.array_layers > 1 && desc.usage & {.ColorAttachment, .DepthStencilAttachment} != {} {
		slot.layer_views = make([]vk.ImageView, desc.array_layers)
		for i in 0 ..< desc.array_layers {
			slot.layer_views[i] = image_view_create(ctx, &slot, .D2, 0, 1, i, 1)
		}
	}

	if desc.mip_levels > 1 && desc.usage & {.Storage} != {} {
		slot.mip_views = make([]vk.ImageView, desc.mip_levels)
		for i in 0 ..< desc.mip_levels {
			slot.mip_views[i] = image_view_create(ctx, &slot, .D2, i, 1, 0, 1)
		}
	}

	return handles.pool_alloc(&ctx.images, slot)
}

device_max_anisotropy :: proc(ctx: ^Context) -> f32 {
	return vk_get_physical_device_properties(ctx).limits.maxSamplerAnisotropy
}

// Frees the handle now; the Vulkan objects are released once in-flight frames are done with them.
image_destroy :: proc(ctx: ^Context, img: Image) {
	release_deferred(ctx, image_slot(ctx, img)^)
	handles.pool_free(&ctx.images, img)
}

@(private)
image_slot_release :: proc(ctx: ^Context, slot: ImageSlot) {
	vk.DestroyImageView(ctx.device, slot.view, nil)
	for view in slot.mip_views do vk.DestroyImageView(ctx.device, view, nil)
	delete(slot.mip_views)
	for view in slot.layer_views do vk.DestroyImageView(ctx.device, view, nil)
	delete(slot.layer_views)
	delete(slot.layout)
	vma.destroy_image(ctx.vma_allocator, slot.image, slot.alloc)
}

// View to render into one (layer, mip) of an image. Falls back to the whole view for
// single-layer images.
@(private)
image_attachment_view :: proc(slot: ^ImageSlot, layer: u32, mip: u32 = 0) -> vk.ImageView {
	assert(mip == 0, "mip attachment views not implemented yet")
	if len(slot.layer_views) == 0 {
		assert(layer == 0, "image has no layer views")
		return slot.view
	}
	return slot.layer_views[layer]
}

// View of one mip level for sampling or storage; single-mip images use the whole view.
@(private)
image_mip_view :: proc(slot: ^ImageSlot, mip: Maybe(u32)) -> vk.ImageView {
	if m, ok := mip.?; ok && len(slot.mip_views) > 0 do return slot.mip_views[m]
	return slot.view
}

@(private)
image_view_create :: proc(
	ctx: ^Context,
	slot: ^ImageSlot,
	view_type: vk.ImageViewType,
	base_mip, mip_count, base_layer, layer_count: u32,
) -> vk.ImageView {
	format := format_to_vk(slot.desc.format)
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = slot.image,
		viewType = view_type,
		format = format,
		subresourceRange = {
			aspectMask = format_aspect_mask(format),
			baseMipLevel = base_mip,
			levelCount = mip_count,
			baseArrayLayer = base_layer,
			layerCount = layer_count,
		},
	}
	view: vk.ImageView
	vk_check(vk.CreateImageView(ctx.device, &info, nil, &view))
	return view
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
	.Shader_Read  = {.SHADER_READ_ONLY_OPTIMAL, {.SHADER_READ}, {.FRAGMENT_SHADER, .COMPUTE_SHADER}},
	.General      = {.GENERAL, {.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE}, {.COMPUTE_SHADER}},
}

layout_to_state_kind :: proc(layout: vk.ImageLayout) -> ImageState {
	for state in IMAGE_STATES {
		if state.layout == layout {
			return state
		}
	}
	log.panicf("no ImageState registered for layout %v", layout)
}

image_barrier :: proc {
	image_barrier_gpu,
	image_barrier_compute,
	image_barrier_raw,
}

// Barriers between dispatches are legal inside a compute pass (unlike a render pass).
image_barrier_compute :: proc(
	enc: ComputeEncoder,
	img: Image,
	dst: ImageStateKind,
	aspect_mask: ImageAspectFlags,
	base_mip_level: u32 = 0,
	level_count: u32 = 1,
	base_array_layer: u32 = 0,
	layer_count: u32 = 1,
) {
	image_barrier_gpu(
		CommandBuffer(enc),
		img,
		dst,
		aspect_mask,
		base_mip_level,
		level_count,
		base_array_layer,
		layer_count,
	)
}

image_barrier_gpu :: proc(
	cmd: CommandBuffer,
	img: Image,
	dst: ImageStateKind,
	aspect_mask: ImageAspectFlags,
	base_mip_level: u32 = 0,
	level_count: u32 = 1,
	base_array_layer: u32 = 0,
	layer_count: u32 = 1,
) {
	slot := image_slot(cmd.ctx, img)
	src := layout_to_state_kind(slot.layout[image_layout_index(slot, base_mip_level, base_array_layer)])
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
		image               = slot.image,
		subresourceRange    = {
			image_aspect_to_vk(aspect_mask),
			base_mip_level,
			level_count,
			base_array_layer,
			layer_count,
		},
	}
	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd.handle, &dep_info)

	for m in base_mip_level ..< base_mip_level + level_count {
		for l in base_array_layer ..< base_array_layer + layer_count {
			slot.layout[image_layout_index(slot, m, l)] = dst.layout
		}
	}
}

// for raw vk.Image handles with no Image slot (e.g. swapchain images), where the
// caller must track/know the current layout itself.
image_barrier_raw :: proc(
	cmd: CommandBuffer,
	img: vk.Image,
	src, dst: ImageStateKind,
	aspect_mask: vk.ImageAspectFlags,
	base_mip_level: u32 = 0,
	level_count: u32 = 1,
	base_array_layer: u32 = 0,
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
		subresourceRange    = {aspect_mask, base_mip_level, level_count, base_array_layer, layer_count},
	}
	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd.handle, &dep_info)
}

// image helpers

generate_mipmaps :: proc(ctx: ^Context, img: Image) {
	slot := image_slot(ctx, img)
	format_props := vk_get_physical_device_format_properties(ctx, format_to_vk(slot.desc.format))

	if .SAMPLED_IMAGE_FILTER_LINEAR not_in format_props.optimalTilingFeatures {
		log.panicf("Texture image format does not support linear blitting")
	}

	mip_levels := slot.desc.mip_levels

	{
		cmd := immediate_submit(ctx)

		mip_width, mip_height := slot.desc.extent.width, slot.desc.extent.height
		for i in 1 ..< mip_levels {
			image_barrier(cmd, img, .Transfer_Src, ImageAspectFlags{.Color}, level_count = 1, base_mip_level = i - 1)

			blit := vk.ImageBlit2 {
				sType = .IMAGE_BLIT_2,
				srcSubresource = {aspectMask = {.COLOR}, mipLevel = i - 1, layerCount = 1},
				srcOffsets = {{0, 0, 0}, {i32(mip_width), i32(mip_height), 1}},
				dstSubresource = {aspectMask = {.COLOR}, mipLevel = i, layerCount = 1},
				dstOffsets = {{0, 0, 0}, {i32(max(mip_width / 2, 1)), i32(max(mip_height / 2, 1)), 1}},
			}
			blit_info := vk.BlitImageInfo2 {
				sType          = .BLIT_IMAGE_INFO_2,
				srcImage       = slot.image,
				srcImageLayout = .TRANSFER_SRC_OPTIMAL,
				dstImage       = slot.image,
				dstImageLayout = .TRANSFER_DST_OPTIMAL,
				regionCount    = 1,
				pRegions       = &blit,
				filter         = .LINEAR,
			}
			vk.CmdBlitImage2(cmd.handle, &blit_info)

			image_barrier(cmd, img, .Shader_Read, ImageAspectFlags{.Color}, level_count = 1, base_mip_level = i - 1)

			if mip_width > 1 do mip_width /= 2
			if mip_height > 1 do mip_height /= 2
		}

		image_barrier(
			cmd,
			img,
			.Shader_Read,
			ImageAspectFlags{.Color},
			level_count = 1,
			base_mip_level = mip_levels - 1,
		)
	}
}

@(private)
copy_image_to_image :: proc(cmd: CommandBuffer, src, dst: vk.Image, src_extent, dst_extent: Extent2D) {
	blit_region := vk.ImageBlit2 {
		sType = .IMAGE_BLIT_2,
		srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
	}
	blit_region.srcOffsets[1] = {i32(src_extent.width), i32(src_extent.height), 1}
	blit_region.dstOffsets[1] = {i32(dst_extent.width), i32(dst_extent.height), 1}

	vk.CmdBlitImage2(
		cmd.handle,
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

copy_buffer_to_image :: proc(cmd: CommandBuffer, buffer: Buffer($T), img: Image, width, height: u32) {
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
		cmd.handle,
		&vk.CopyBufferToImageInfo2 {
			sType = .COPY_BUFFER_TO_IMAGE_INFO_2,
			srcBuffer = buffer_slot(cmd.ctx, buffer).buffer,
			dstImage = image_slot(cmd.ctx, img).image,
			dstImageLayout = .TRANSFER_DST_OPTIMAL,
			regionCount = 1,
			pRegions = &region,
		},
	)
}

copy_image_to_buffer :: proc(cmd: CommandBuffer, img: Image, buffer: Buffer($T), width, height: u32) {
	region := vk.BufferImageCopy2 {
		sType = .BUFFER_IMAGE_COPY_2,
		bufferOffset = 0,
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		imageOffset = {0, 0, 0},
		imageExtent = {width, height, 1},
	}

	vk.CmdCopyImageToBuffer2(
		cmd.handle,
		&vk.CopyImageToBufferInfo2 {
			sType = .COPY_IMAGE_TO_BUFFER_INFO_2,
			srcImage = image_slot(cmd.ctx, img).image,
			srcImageLayout = .TRANSFER_SRC_OPTIMAL,
			dstBuffer = buffer_slot(cmd.ctx, buffer).buffer,
			regionCount = 1,
			pRegions = &region,
		},
	)
}

copy_buffer_to_cubemap :: proc(
	cmd: CommandBuffer,
	buffer: Buffer($T),
	img: Image,
	face_w, face_h: u32,
	face_size: u32,
) {
	regions: [6]vk.BufferImageCopy2
	for i in 0 ..< 6 {
		regions[i] = vk.BufferImageCopy2 {
			sType = .BUFFER_IMAGE_COPY_2,
			bufferOffset = vk.DeviceSize(u32(i) * face_size),
			imageSubresource = {aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = u32(i), layerCount = 1},
			imageExtent = {face_w, face_h, 1},
		}
	}

	vk.CmdCopyBufferToImage2(
		cmd.handle,
		&vk.CopyBufferToImageInfo2 {
			sType = .COPY_BUFFER_TO_IMAGE_INFO_2,
			srcBuffer = buffer_slot(cmd.ctx, buffer).buffer,
			dstImage = image_slot(cmd.ctx, img).image,
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
	compare_op:               CompareOp,
	min_lod, max_lod:         f32,
	border_color:             BorderColor,
	unnormalized_coordinates: bool,
}

border_color_to_vk :: proc(color: BorderColor) -> vk.BorderColor {
	switch color {
	case .TransparentBlack:
		return .FLOAT_TRANSPARENT_BLACK
	case .OpaqueBlack:
		return .FLOAT_OPAQUE_BLACK
	case .OpaqueWhite:
		return .FLOAT_OPAQUE_WHITE
	}
	return .FLOAT_OPAQUE_WHITE
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
		compare_op = .Always,
		max_lod = 1.0,
		border_color = .OpaqueWhite,
	}
}

sampler_create :: proc(ctx: ^Context, desc: SamplerDesc) -> Sampler {
	info := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		minFilter               = texture_filter_to_backend(desc.min_filter),
		magFilter               = texture_filter_to_backend(desc.mag_filter),
		mipmapMode              = desc.mipmap_mode,
		addressModeU            = texture_repeat_to_backend(desc.address_mode_u),
		addressModeV            = texture_repeat_to_backend(desc.address_mode_v),
		addressModeW            = texture_repeat_to_backend(desc.address_mode_w),
		mipLodBias              = desc.mip_lod_bias,
		anisotropyEnable        = b32(desc.anisotropy_enable),
		maxAnisotropy           = desc.max_anisotropy,
		compareEnable           = b32(desc.compare_enable),
		compareOp               = compare_op_to_vk(desc.compare_op),
		minLod                  = desc.min_lod,
		maxLod                  = desc.max_lod,
		borderColor             = border_color_to_vk(desc.border_color),
		unnormalizedCoordinates = b32(desc.unnormalized_coordinates),
	}
	sampler: vk.Sampler
	vk_check(vk.CreateSampler(ctx.device, &info, nil, &sampler))
	return Sampler(sampler)
}

sampler_destroy :: proc(ctx: ^Context, sampler: Sampler) {
	vk.DestroySampler(ctx.device, vk.Sampler(sampler), nil)
}

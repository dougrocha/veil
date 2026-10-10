package backend

import vk "vendor:vulkan"

// Copies a color image back to CPU memory as tightly packed RGBA8. The caller
// owns the returned slice. Only used by the frame dump, so it takes the simple
// route: a blocking blit into an RGBA8 image (handles format conversion from
// the HDR draw target), then a copy into a mapped staging buffer.
image_read_rgba8 :: proc(ctx: ^Context, img: Image, allocator := context.allocator) -> []u8 {
	extent := image_desc(ctx, img).extent
	width := extent.width
	height := extent.height
	size := int(width) * int(height) * 4

	rgba_img := image_create(ctx, image_desc_default(extent, .Rgba8_Unorm, {.TransferDst, .TransferSrc}))
	defer image_destroy(ctx, rgba_img)

	staging := buffer_create(u8, ctx, size, {.Transfer_Dst}, .Readback)
	defer buffer_destroy(ctx, staging)

	{
		cmd := immediate_submit(ctx)
		image_barrier(cmd, img, .Transfer_Src, ImageAspectFlags{.Color})
		image_barrier(cmd, rgba_img, .Transfer_Dst, ImageAspectFlags{.Color})

		blit_region := vk.ImageBlit2 {
			sType = .IMAGE_BLIT_2,
			srcSubresource = {aspectMask = {.COLOR}, layerCount = 1},
			dstSubresource = {aspectMask = {.COLOR}, layerCount = 1},
		}
		blit_region.srcOffsets[1] = {i32(width), i32(height), 1}
		blit_region.dstOffsets[1] = {i32(width), i32(height), 1}

		vk.CmdBlitImage2(
			cmd.handle,
			&vk.BlitImageInfo2 {
				sType = .BLIT_IMAGE_INFO_2,
				srcImage = image_slot(ctx, img).image,
				srcImageLayout = .TRANSFER_SRC_OPTIMAL,
				dstImage = image_slot(ctx, rgba_img).image,
				dstImageLayout = .TRANSFER_DST_OPTIMAL,
				filter = .NEAREST,
				regionCount = 1,
				pRegions = &blit_region,
			},
		)

		image_barrier(cmd, rgba_img, .Transfer_Src, ImageAspectFlags{.Color})
		copy_image_to_buffer(cmd, rgba_img, staging, width, height)
	}

	out := make([]u8, size, allocator)
	buffer_read(ctx, staging, out)
	return out
}

package graphics

import "core:log"

import vk "vendor:vulkan"

vk_check :: proc(result: vk.Result, loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("Vulkan failure: %v", result, location = loc)
	}
}

create_image_view :: proc(
	engine: ^Engine,
	img: vk.Image,
	format: vk.Format,
	aspect: vk.ImageAspectFlags,
	view: ^vk.ImageView,
) {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = img,
		viewType = .D2,
		format = format,
		subresourceRange = {aspectMask = aspect, baseMipLevel = 0, levelCount = 1, baseArrayLayer = 0, layerCount = 1},
	}
	vk_check(vk.CreateImageView(engine.device, &info, nil, view))
}

begin_single_time_commands :: proc(engine: ^Engine) -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = engine.frame_resources[0].command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	cmd: vk.CommandBuffer
	vk_check(vk.AllocateCommandBuffers(engine.device, &alloc_info, &cmd))
	vk_check(
		vk.BeginCommandBuffer(
			cmd,
			&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)
	return cmd
}

end_single_time_commands :: proc(engine: ^Engine, cmd: ^vk.CommandBuffer) {
	vk_check(vk.EndCommandBuffer(cmd^))

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd^,
	}
	submit_info := vk.SubmitInfo2 {
		sType                  = .SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &cmd_info,
	}
	vk_check(vk.QueueSubmit2(engine.graphics_queue, 1, &submit_info, 0))
	vk_check(vk.QueueWaitIdle(engine.graphics_queue))
	vk.FreeCommandBuffers(engine.device, engine.frame_resources[0].command_pool, 1, cmd)
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
		subresourceRange = {aspectMask = aspect, levelCount = 1, layerCount = 1},
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


package graphics

import "core:log"
import "core:os"

import vk "vendor:vulkan"

vk_check :: #force_inline proc(result: vk.Result, message := "Vulkan Error", loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("[Vulkan Failure] %s: %v", message, result, loc)
	}
}

begin_single_time_commands :: proc(ctx: ^VulkanContext) -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = ctx.upload_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	cmd: vk.CommandBuffer
	vk_check(vk.AllocateCommandBuffers(ctx.device, &alloc_info, &cmd))
	vk_check(
		vk.BeginCommandBuffer(
			cmd,
			&vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}},
		),
	)
	return cmd
}

end_single_time_commands :: proc(ctx: ^VulkanContext, cmd: ^vk.CommandBuffer) {
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
	vk_check(vk.QueueSubmit2(ctx.graphics_queue, 1, &submit_info, 0))
	vk_check(vk.QueueWaitIdle(ctx.graphics_queue))
	vk.FreeCommandBuffers(ctx.device, ctx.upload_pool, 1, cmd)
}

get_physical_device_properties :: proc(ctx: ^VulkanContext) -> vk.PhysicalDeviceProperties {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(ctx.physical_device, &properties)
	return properties
}

get_physical_device_format_properties :: proc(ctx: ^VulkanContext, format: vk.Format) -> vk.FormatProperties {
	format_props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(ctx.physical_device, format, &format_props)
	return format_props
}

read_file :: proc(filepath: string, allocator := context.allocator) -> string {
	buf, err := os.read_entire_file(filepath, allocator)
	log.assertf(err == os.ERROR_NONE, "Failed to read file '%s': %v", filepath, err)
	return string(buf)
}


package graphics

import "core:log"

import vk "vendor:vulkan"

vk_check :: #force_inline proc(result: vk.Result, message := "Vulkan Error", loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("[Vulkan Failure] %s: %v", message, result, loc)
	}
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


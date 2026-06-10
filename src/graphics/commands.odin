package graphics

import vk "vendor:vulkan"

create_command_buffers :: proc(self: ^Engine) {
	for &res in self.frame_resources {
		pool_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			queueFamilyIndex = self.gfx_queue_fam_idx,
		}

		vk_check(vk.CreateCommandPool(self.device, &pool_info, nil, &res.command_pool))

		cmd_alloc_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = res.command_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}

		vk_check(vk.AllocateCommandBuffers(self.device, &cmd_alloc_info, &res.command_buffer))
	}
}

create_sync_resources :: proc(self: ^Engine) {
	semaphore_type_info := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
		initialValue  = 0,
	}

	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &semaphore_type_info,
	}

	vk_check(vk.CreateSemaphore(self.device, &semaphore_info, nil, &self.timeline_semaphore))

	for &res in self.frame_resources {
		binary_semaphore_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_check(vk.CreateSemaphore(self.device, &binary_semaphore_info, nil, &res.image_acquired_semaphore))
		vk_check(vk.CreateSemaphore(self.device, &binary_semaphore_info, nil, &res.render_complete_semaphore))
	}
}


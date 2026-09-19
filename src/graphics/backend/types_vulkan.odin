#+build linux

package backend

import "core:log"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

SWAPCHAIN_FORMAT :: vk.Format.B8G8R8A8_SRGB
DEPTH_FORMAT :: vk.Format.D32_SFLOAT
DRAW_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

CommandBuffer :: distinct vk.CommandBuffer
RenderEncoder :: CommandBuffer
ComputeEncoder :: CommandBuffer
Sampler :: distinct vk.Sampler

load_op_to_vk :: proc(op: LoadOp) -> vk.AttachmentLoadOp {
	switch op {
	case .Clear:
		return .CLEAR
	case .Load:
		return .LOAD
	case .Dont_Care:
		return .DONT_CARE
	}
	return .DONT_CARE
}

Context :: struct {
	instance:                        vk.Instance,
	surface:                         vk.SurfaceKHR,
	physical_device:                 vk.PhysicalDevice,
	device:                          vk.Device,
	vma_allocator:                   vma.Allocator,
	logger:                          log.Logger,
	debug_messenger:                 vk.DebugUtilsMessengerEXT,
	gfx_queue_fam_idx:               u32,
	graphics_queue:                  vk.Queue,
	msaa_samples:                    vk.SampleCountFlags,
	upload_pool:                     vk.CommandPool,
	max_bindless_samplers_per_stage: u32,
	timeline_semaphore:              vk.Semaphore,
	frame_sync:                      [MAX_FRAMES_IN_FLIGHT]FrameSync,
}

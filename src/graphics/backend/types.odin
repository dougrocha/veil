package backend

import "core:log"

import vma "shared:odin-vma"
import vk "vendor:vulkan"

import "../../handles"

MAX_FRAMES_IN_FLIGHT :: 2

// Validation layers cost CPU on every command; release builds pass -define:VEIL_VALIDATION=false.
VEIL_VALIDATION :: #config(VEIL_VALIDATION, true)

// Timestamp queries per frame slot (GpuTimer).
MAX_GPU_TIMESTAMPS :: 64

ImageUsage :: enum {
	TransferSrc,
	TransferDst,
	Sampled,
	Storage,
	ColorAttachment,
	DepthStencilAttachment,
	Transient,
}

ImageUsageFlags :: bit_set[ImageUsage]

ImageAspect :: enum {
	Color,
	Depth,
	Stencil,
}

ImageAspectFlags :: bit_set[ImageAspect]

ImageStateKind :: enum {
	Undefined,
	Depth_Write,
	Depth_Read,
	Color_Write,
	Transfer_Src,
	Transfer_Dst,
	Present,
	Shader_Read,
	General, // compute storage-image read/write
}

BorderColor :: enum {
	TransparentBlack,
	OpaqueBlack,
	OpaqueWhite,
}

CompareOp :: enum {
	Never,
	Less,
	Equal,
	LessOrEqual,
	Greater,
	NotEqual,
	GreaterOrEqual,
	Always,
}

LoadOp :: enum u8 {
	Clear,
	Load,
	Dont_Care,
}

SWAPCHAIN_FORMAT :: vk.Format.B8G8R8A8_SRGB
DEPTH_FORMAT :: Format.D32_Sfloat
DRAW_FORMAT :: Format.Rgba16_Sfloat

Extent2D :: struct {
	width, height: u32,
}

Extent3D :: struct {
	width, height, depth: u32,
}

// Recording target for GPU commands. Carries the context so calls like image_barrier can
// look up image state from a handle; its fields are backend-only.
CommandBuffer :: struct {
	handle: vk.CommandBuffer,
	ctx:    ^Context,
}
// Recording inside a render pass (draws) or a compute pass (dispatches). Distinct types so a
// draw can't be recorded in a compute pass, a dispatch in a render pass, or a barrier in either
// render pass (image_barrier accepts CommandBuffer and ComputeEncoder only).
RenderEncoder :: distinct CommandBuffer
ComputeEncoder :: distinct CommandBuffer
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
	msaa_samples:                    u32, // highest count usable for color + depth
	upload_pool:                     vk.CommandPool,
	max_bindless_textures_per_stage: u32,
	timeline_semaphore:              vk.Semaphore,
	frame_sync:                      [MAX_FRAMES_IN_FLIGHT]FrameSync,
	frame_index:                     u64, // frames submitted; the frame being recorded signals frame_index + 1
	images:                          handles.Pool(ImageSlot),
	buffers:                         handles.Pool(BufferSlot),
	pending_releases:                [dynamic]PendingRelease, // destroyed handles awaiting GPU completion
}

#+build darwin

package backend

import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import sdl "vendor:sdl3"

SWAPCHAIN_FORMAT :: MTL.PixelFormat.BGRA8Unorm
DEPTH_FORMAT :: MTL.PixelFormat.Depth32Float
// present_blit uses a Metal texture copy, which requires matching source and
// destination pixel formats. Use the layer's format until presentation is a
// render/compute conversion pass that can preserve an HDR intermediate.
DRAW_FORMAT :: SWAPCHAIN_FORMAT

CommandBuffer :: distinct ^MTL.CommandBuffer
RenderEncoder :: distinct ^MTL.RenderCommandEncoder
ComputeEncoder :: distinct ^MTL.ComputeCommandEncoder
Sampler :: distinct ^MTL.SamplerState

load_op_to_mtl :: proc(op: LoadOp) -> MTL.LoadAction {
	switch op {
	case .Clear:
		return .Clear
	case .Load:
		return .Load
	case .Dont_Care:
		return .DontCare
	}
	return .DontCare
}

Context :: struct {
	device:                          ^MTL.Device,
	command_queue:                   ^MTL.CommandQueue,
	metal_view:                      sdl.MetalView,
	layer:                           ^CA.MetalLayer,
	max_bindless_textures_per_stage: u32,
	msaa_samples:                    u32,
	frame_sync:                      [MAX_FRAMES_IN_FLIGHT]FrameSync,
	immediate_pool:                  rawptr,
}

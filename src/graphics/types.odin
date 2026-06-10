package graphics

import "base:runtime"
import "core:time"

import sp "shared:odin-slang/slang"
import vma "shared:odin-vma"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

SWAPCHAIN_FORMAT :: vk.Format.B8G8R8A8_SRGB
DEPTH_FORMAT :: vk.Format.D32_SFLOAT
TEXTURE_FORMAT :: vk.Format.R8G8B8A8_SRGB
MAX_FRAMES_IN_FLIGHT :: 2

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

Mat4x4 :: matrix[4, 4]f32
Mat4x3 :: matrix[4, 3]f32

UniformBufferObject :: struct #align (16) {
	model:     Mat4x4,
	view:      Mat4x4,
	proj:      Mat4x4,
	light_pos: Vec4,
}

g_ctx: runtime.Context

FrameResources :: struct {
	command_pool:              vk.CommandPool,
	command_buffer:            vk.CommandBuffer,
	image_acquired_semaphore:  vk.Semaphore,
	render_complete_semaphore: vk.Semaphore,
}

App :: struct {
	window: ^sdl.Window,
	width:  u32,
	height: u32,
	engine: Engine,
}

Engine :: struct {
	// core
	instance:                   vk.Instance,
	surface:                    vk.SurfaceKHR,
	physical_device:            vk.PhysicalDevice,
	device:                     vk.Device,
	vma_allocator:              vma.Allocator,

	// queue
	gfx_queue_fam_idx:          u32,
	graphics_queue:             vk.Queue,

	// swapchain
	swapchain:                  vk.SwapchainKHR,
	swapchain_images:           []vk.Image,
	swapchain_image_view:       []vk.ImageView,
	require_swapchain_recreate: bool,
	swapchain_width:            u32,
	swapchain_height:           u32,
	depth_image:                vk.Image,
	depth_image_view:           vk.ImageView,
	depth_image_allocation:     vma.Allocation,
	color_image:                vk.Image,
	color_image_view:           vk.ImageView,
	color_image_allocation:     vma.Allocation,

	// shaders
	slang_session:              ^sp.IGlobalSession,
	shader_module:              vk.ShaderModule,

	// graphics pipeline
	pipeline:                   vk.Pipeline,
	pipeline_layout:            vk.PipelineLayout,
	descriptor_pool:            vk.DescriptorPool,
	descriptor_set_layout:      vk.DescriptorSetLayout,
	descriptor_sets:            [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,

	// frame and sync resources
	timeline_semaphore:         vk.Semaphore,
	frame_resources:            [MAX_FRAMES_IN_FLIGHT]FrameResources,
	frame_index:                u64,
	next_signal_value:          u64,

	// buffers
	vertices:                   []Vertex,
	indices:                    []u32,
	geometry_buffer:            vk.Buffer,
	geometry_buffer_allocation: vma.Allocation,
	geometry_buffer_address:    vk.DeviceAddress,
	index_buffer_offset:        vk.DeviceSize,

	// uniform buffers (one per frame in flight)
	uniform_buffers:            [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	uniform_buffer_allocations: [MAX_FRAMES_IN_FLIGHT]vma.Allocation,
	uniform_buffers_mapped:     [MAX_FRAMES_IN_FLIGHT]rawptr,

	// timers
	start_time:                 time.Time,
	last_frame_time:            time.Time,
	delta_time:                 f32,

	// camera
	camera:                     Camera,

	// texture
	mip_levels:                 u32,
	texture_image:              vk.Image,
	texture_image_allocation:   vma.Allocation,
	texture_image_view:         vk.ImageView,
	texture_sampler:            vk.Sampler,
	msaa_samples:               vk.SampleCountFlags,
}

Vertex :: struct {
	pos:       Vec3,
	color:     Vec3,
	tex_coord: Vec2,
	normal:    Vec3,
}

vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
}

vertex_attribute_descriptions :: proc() -> [4]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, color))},
		{location = 2, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, tex_coord))},
		{location = 3, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, normal))},
	}
}

PushConstants :: struct {
	data:                  Vec4,
	vertex_buffer_address: vk.DeviceAddress,
}


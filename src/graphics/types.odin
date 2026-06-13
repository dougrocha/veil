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
DRAW_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

MAX_FRAMES_IN_FLIGHT :: 2

PARTICLE_COUNT :: 8192

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Quat :: quaternion128

Mat4x4 :: matrix[4, 4]f32
Mat4x3 :: matrix[4, 3]f32


g_ctx: runtime.Context

FrameResources :: struct {
	command_pool:              vk.CommandPool,
	command_buffer:            vk.CommandBuffer,
	image_acquired_semaphore:  vk.Semaphore,
	render_complete_semaphore: vk.Semaphore,
	deletion_queue:            DeletionQueue,
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
	swapchain_extent:           vk.Extent2D,
	depth_image:                GpuImage,
	color_image:                GpuImage,
	draw_image:                 GpuImage,

	// shaders
	slang_session:              ^sp.IGlobalSession,
	shader_module:              vk.ShaderModule,

	// graphics pipeline
	pipeline:                   Pipeline,
	descriptor_pool:            vk.DescriptorPool,
	descriptor_set_layout:      vk.DescriptorSetLayout,
	descriptor_sets:            [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	compute_pipeline:           Pipeline,

	// frame and sync resources
	timeline_semaphore:         vk.Semaphore,
	frame_resources:            [MAX_FRAMES_IN_FLIGHT]FrameResources,
	frame_index:                u64,
	next_signal_value:          u64,

	// buffers
	model_system:               ModelSystem,
	material_system:            MaterialSystem,
	scene_data_buffers:         [MAX_FRAMES_IN_FLIGHT]GpuBuffer,
	particle_buffers:           [MAX_FRAMES_IN_FLIGHT]GpuBuffer,

	// timers
	start_time:                 time.Time,
	last_frame_time:            time.Time,
	delta_time:                 f32,
	fps_timer:                  f32,
	fps_frame_count:            u32,

	// camera
	camera:                     Camera,

	// texture
	texture_system:             TextureSystem,
	msaa_samples:               vk.SampleCountFlags,
}

SceneData :: struct #align (16) {
	view:       Mat4x4,
	proj:       Mat4x4,
	light_pos:  Vec4,
	delta_time: f32,
}

Vertex :: struct {
	pos:       Vec3,
	color:     Vec3,
	normal:    Vec3,
	tex_coord: Vec2,
}

PushConstants :: struct {
	model:                   Mat4x4,
	scene_data:              vk.DeviceAddress,
	vertex_buffer_address:   vk.DeviceAddress,
	material_buffer_address: vk.DeviceAddress,
	material_index:          u32,
}

ComputePushConstants :: struct {
	delta_time:    f32,
	particles_in:  vk.DeviceAddress,
	particles_out: vk.DeviceAddress,
}

Transform :: struct {
	translation: Vec3,
	rotation:    Quat,
	scale:       Vec3,
}

Mesh :: struct {
	vertex_buffer:     vk.Buffer,
	vertex_allocation: vma.Allocation,
	vertex_address:    vk.DeviceAddress,
	index_buffer:      vk.Buffer,
	index_allocation:  vma.Allocation,
	index_count:       u32,
	material_index:    i32,
}

Particle :: struct {
	position: Vec2,
	velocity: Vec2,
	color:    Vec4,
}

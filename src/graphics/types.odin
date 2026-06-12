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
MAX_TEXTURES :: 1024

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

	// shaders
	slang_session:              ^sp.IGlobalSession,
	shader_module:              vk.ShaderModule,

	// graphics pipeline
	pipeline:                   Pipeline,
	descriptor_pool:            vk.DescriptorPool,
	descriptor_set_layout:      vk.DescriptorSetLayout,
	descriptor_sets:            [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,

	// frame and sync resources
	timeline_semaphore:         vk.Semaphore,
	frame_resources:            [MAX_FRAMES_IN_FLIGHT]FrameResources,
	frame_index:                u64,
	next_signal_value:          u64,

	// buffers
	meshes:                     [dynamic]Mesh,
	materials:                  [dynamic]Material,
	material_buffer:            GpuBuffer,
	scene_data_buffers:         [MAX_FRAMES_IN_FLIGHT]GpuBuffer,

	// timers
	start_time:                 time.Time,
	last_frame_time:            time.Time,
	delta_time:                 f32,

	// camera
	camera:                     Camera,

	// texture
	textures:                   [dynamic]Texture,
	msaa_samples:               vk.SampleCountFlags,
}

SceneData :: struct #align (16) {
	view:      Mat4x4,
	proj:      Mat4x4,
	light_pos: Vec4,
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

Material :: struct {
	base_color:               Vec4,
	metallic:                 f32,
	roughness:                f32,
	emissive:                 Vec3,
	base_color_texture_index: i32,
	metallic_texture_index:   i32,
	normal_texture_index:     i32,
	roughness_texture_index:  i32,
	emissive_texture_index:   i32,
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
	transform:         Transform,
}

Texture :: struct {
	image:      vk.Image,
	allocation: vma.Allocation,
	image_view: vk.ImageView,
	sampler:    vk.Sampler,
	mip_levels: u32,
}


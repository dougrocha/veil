package graphics

import "base:runtime"
import "core:math/linalg"
import "core:time"

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

vec3_splat :: proc(v: f32) -> Vec3 {return {v, v, v}}


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
	shader_system:              ShaderSystem,

	// graphics pipeline
	pipeline:                   Pipeline,
	particle_draw_pipeline:     Pipeline,
	descriptor_pool:            vk.DescriptorPool,
	descriptor_set_layout:      vk.DescriptorSetLayout,
	descriptor_sets:            [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,
	particle_pipeline:          Pipeline,

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
	ambient_light:              AmbientLight,

	// texture
	texture_system:             TextureSystem,
	msaa_samples:               vk.SampleCountFlags,
}

PointLight :: struct {
	pos:       Vec3,
	constant:  f32,
	color:     Vec3,
	linear:    f32,
	quadratic: f32,
}

DirectionalLight :: struct {
	direction: Vec3,
	color:     Vec3,
}

SpotLight :: struct {
	pos:          Vec3,
	inner_cutoff: f32,
	direction:    Vec3,
	outer_cutoff: f32,
	color:        Vec3,
	constant:     f32,
	linear:       f32,
	quadratic:    f32,
}

AlphaMode :: enum {
	Opaque,
	Mask,
	Blend,
}

AmbientLight :: struct {
	color:      Vec4,
	brightness: f32,
}

SceneData :: struct {
	view:                    Mat4x4,
	proj:                    Mat4x4,
	point_lights:            [16]PointLight,
	directional_lights:      [4]DirectionalLight,
	spot_lights:             [4]SpotLight,
	cam_pos:                 Vec3,
	delta_time:              f32,
	ambient_light:           AmbientLight,
	point_light_count:       u32,
	directional_light_count: u32,
	spot_light_count:        u32,
}

Vertex :: struct {
	pos:    Vec3,
	uv:     Vec2,
	color:  Vec3,
	normal: Vec3,
}

PushConstants :: struct {
	scene_data:       vk.DeviceAddress,
	vertex_buffer:    vk.DeviceAddress,
	material_buffer:  vk.DeviceAddress,
	transform_buffer: vk.DeviceAddress,
	material_index:   u32,
	instance_index:   u32,
}

ParticlePushConstants :: struct {
	scene_data:    vk.DeviceAddress,
	particles_in:  vk.DeviceAddress,
	particles_out: vk.DeviceAddress,
	delta_time:    f32,
}

Transform :: struct {
	translation: Vec3,
	rotation:    Quat,
	scale:       Vec3,
}

GpuTransform :: struct {
	model:         Mat4x4,
	normal_matrix: Mat4x4,
}

transform_create :: proc(
	translation: Vec3 = {},
	rotation: Quat = linalg.QUATERNIONF32_IDENTITY,
	scale: Vec3 = {1, 1, 1},
) -> Transform {
	return Transform{translation = translation, rotation = rotation, scale = scale}
}

Particle :: struct {
	position: Vec4,
	velocity: Vec4,
	color:    Vec4,
}

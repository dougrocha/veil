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
	scene_data_buffer:         GpuBuffer,
	particle_buffer:           GpuBuffer,
}

Swapchain :: struct {
	handle:           vk.SwapchainKHR,
	images:           []vk.Image,
	image_views:      []vk.ImageView,
	require_recreate: bool,
	extent:           vk.Extent2D,
	depth_image:      GpuImage,
	color_image:      GpuImage,
	draw_image:       GpuImage,
}

Clock :: struct {
	start_time:      time.Time,
	last_frame_time: time.Time,
	delta_time:      f32,
	fps_timer:       f32,
	fps_frame_count: u32,
}

App :: struct {
	window: ^sdl.Window,
	width:  u32,
	height: u32,
	engine: Engine,
}

VulkanContext :: struct {
	// core
	instance:          vk.Instance,
	surface:           vk.SurfaceKHR,
	physical_device:   vk.PhysicalDevice,
	device:            vk.Device,
	vma_allocator:     vma.Allocator,

	// queue
	gfx_queue_fam_idx: u32,
	graphics_queue:    vk.Queue,
	msaa_samples:      vk.SampleCountFlags,
	upload_pool:       vk.CommandPool,
}

Engine :: struct {
	vk_ctx:                  VulkanContext,

	// swapchain
	swapchain:               Swapchain,

	// shaders
	shader_system:           ShaderSystem,

	// graphics pipeline
	pipeline_registry:       PipelineRegistry,

	// frame and sync resources
	timeline_semaphore:      vk.Semaphore,
	frame_resources:         [MAX_FRAMES_IN_FLIGHT]FrameResources,
	frame_index:             u64,
	current_image_index:     u32,
	next_signal_value:       u64,

	// buffers
	model_system:            ModelSystem,
	material_system:         MaterialSystem,

	// timers
	clock:                   Clock,

	// camera
	camera:                  Camera,
	ambient_light:           AmbientLight,

	// lights
	point_lights:            [16]PointLight,
	point_light_count:       u32,
	directional_lights:      [4]DirectionalLight,
	directional_light_count: u32,
	spot_lights:             [4]SpotLight,
	spot_light_count:        u32,

	// texture
	texture_system:          TextureSystem,

	// skybox
	skybox_descriptor:       DescriptorSet,
	shadow_map_image:        GpuImage,
	shadow_map_sampler:      vk.Sampler,
	shadow_map_descriptor:   DescriptorSet,
}

PointLight :: struct {
	pos:                Vec3,
	constant:           f32,
	color:              Vec3,
	linear:             f32,
	quadratic:          f32,
	diffuse_intensity:  f32,
	specular_intensity: f32,
}

DirectionalLight :: struct {
	direction:          Vec3,
	color:              Vec3,
	diffuse_intensity:  f32,
	specular_intensity: f32,
}

SpotLight :: struct {
	pos:                Vec3,
	inner_cutoff:       f32,
	direction:          Vec3,
	outer_cutoff:       f32,
	color:              Vec3,
	constant:           f32,
	linear:             f32,
	quadratic:          f32,
	diffuse_intensity:  f32,
	specular_intensity: f32,
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
	light_space_matrix:      Mat4x4,
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

ShadowPushConstants :: struct {
	scene_data:       vk.DeviceAddress,
	vertex_buffer:    vk.DeviceAddress,
	transform_buffer: vk.DeviceAddress,
	instance_index:   u32,
}

PushConstants :: struct {
	scene_data:       vk.DeviceAddress,
	vertex_buffer:    vk.DeviceAddress,
	material_buffer:  vk.DeviceAddress,
	transform_buffer: vk.DeviceAddress,
	material_index:   u32,
	instance_index:   u32,
}

SkyboxPushConstants :: struct {
	scene_data: vk.DeviceAddress,
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
	translation: Vec3 = {0.0, 0.0, 0.0},
	rotation: Quat = linalg.QUATERNIONF32_IDENTITY,
	scale: Vec3 = {1.0, 1.0, 1.0},
) -> Transform {
	return Transform{translation = translation, rotation = rotation, scale = scale}
}

Particle :: struct {
	position: Vec4,
	velocity: Vec4,
	color:    Vec4,
}

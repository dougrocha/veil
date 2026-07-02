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
TEXTURE_FORMAT_LINEAR :: vk.Format.R8G8B8A8_UNORM
DRAW_FORMAT :: vk.Format.R16G16B16A16_SFLOAT

MAX_FRAMES_IN_FLIGHT :: 2
MAX_SHADOW_LIGHTS :: 6

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
	transforms_buffer:         GpuBuffer,
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
	vk_ctx:              VulkanContext,

	// swapchain
	swapchain:           Swapchain,

	// shaders
	shader_system:       ShaderSystem,

	// graphics pipeline
	pipeline_registry:   PipelineRegistry,

	// frame and sync resources
	timeline_semaphore:  vk.Semaphore,
	frame_resources:     [MAX_FRAMES_IN_FLIGHT]FrameResources,
	frame_index:         u64,
	current_image_index: u32,

	// buffers
	model_system:        ModelSystem,
	material_system:     MaterialSystem,

	// timers
	clock:               Clock,

	// texture
	texture_system:      TextureSystem,

	// global resources (binding 0 = shadow map, binding 1 = skybox)
	global_descriptor:   DescriptorSet,
	shadow_atlas:        ShadowAtlas,

	// simulation state — no Vulkan types
	scene:               Scene,

	// stats
	drawn_instance_count: u32,
}

// Everything the game mutates. No Vulkan types in here.
Scene :: struct {
	camera:                  Camera,
	ambient_light:           AmbientLight,
	point_lights:            [16]PointLight,
	directional_lights:      [4]DirectionalLight,
	spot_lights:             [4]SpotLight,
	point_light_count:       u32,
	directional_light_count: u32,
	spot_light_count:        u32,
	instances:               Pool(Instance),
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
	light_view_proj:         [MAX_SHADOW_LIGHTS][6]Mat4x4,
	point_lights:            [16]PointLight,
	directional_lights:      [4]DirectionalLight,
	spot_lights:             [4]SpotLight,
	cam_pos:                 Vec3,
	delta_time:              f32,
	ambient_light:           AmbientLight,
	point_light_count:       u32,
	directional_light_count: u32,
	spot_light_count:        u32,
	shadow_near:             f32,
	shadow_far:              f32,
}

Vertex :: struct {
	pos:     Vec3,
	uv:      Vec2,
	normal:  Vec3,
	tangent: Vec4, // xyz = tangent direction, w = handedness
}

ShadowPushConstants :: struct {
	scene_data:       vk.DeviceAddress,
	vertex_buffer:    vk.DeviceAddress,
	transform_buffer: vk.DeviceAddress,
	instance_index:   u32,
	face_index:       u32,
	light_index:      u32,
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

// Builds the model matrix by combining translation, rotation, and scale
transform_matrix :: proc(transform: Transform) -> Mat4x4 {
	translation := linalg.matrix4_translate(transform.translation)
	rot := linalg.matrix4_from_quaternion(transform.rotation)
	scale := linalg.matrix4_scale(transform.scale)

	return translation * rot * scale
}

transform_global_scale :: proc(transform: Transform) -> Vec3 {
	return transform.scale
}

transform_right :: proc(transform: Transform) -> Vec3 {
	return linalg.quaternion_mul_vector3(transform.rotation, Vec3{1, 0, 0})
}

transform_up :: proc(transform: Transform) -> Vec3 {
	return linalg.quaternion_mul_vector3(transform.rotation, Vec3{0, 1, 0})
}

transform_forward :: proc(transform: Transform) -> Vec3 {
	return linalg.quaternion_mul_vector3(transform.rotation, Vec3{0, 0, -1})
}


Particle :: struct {
	position: Vec4,
	velocity: Vec4,
	color:    Vec4,
}

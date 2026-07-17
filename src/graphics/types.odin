package graphics

import "core:math/linalg"
import "core:time"

import sdl "vendor:sdl3"

import "backend"

MAX_SHADOW_LIGHTS :: 6

PARTICLE_COUNT :: 8192

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32
Quat :: quaternion128

Mat4x4 :: matrix[4, 4]f32
Mat4x3 :: matrix[4, 3]f32

// Screen-space rect, vk.Rect2D-shaped but backend-agnostic so callers don't need to import vk.
Rect2D :: struct {
	offset: [2]i32,
	extent: [2]u32,
}

vec3_splat :: proc(v: f32) -> Vec3 {return {v, v, v}}

App :: struct {
	window:          ^sdl.Window,
	width:           u32,
	height:          u32,
	engine:          Engine,
	last_frame_time: time.Time,
	fps_timer:       f32,
	fps_frame_count: u32,
}

Engine :: struct {
	vk_ctx:               backend.VulkanContext,

	// swapchain
	swapchain:            backend.Swapchain,

	// shaders
	shader_system:        ShaderSystem,

	// graphics pipeline
	pipeline_registry:    PipelineRegistry,

	// frame and sync resources
	frame_data:           [backend.MAX_FRAMES_IN_FLIGHT]FrameData,
	frame_index:          u64,
	current_image_index:  u32,

	// buffers
	model_system:         ModelSystem,
	material_system:      MaterialSystem,

	// timers
	time_info:            TimeInfo,

	// texture
	texture_system:       TextureSystem,

	// global resources (binding 0 = shadow map, binding 1 = skybox)
	global_descriptor:    backend.DescriptorSet,
	shadow_atlas:         ShadowAtlas,
	dir_shadow_atlas:     ShadowAtlas,

	// simulation state — no Vulkan types
	scene:                Scene,
	camera_system:        CameraSystem,

	// stats
	drawn_instance_count: u32,

	// other stuff
	line_renderer:        LineRenderer,
}

// Everything the game mutates. No Vulkan types in here.
Scene :: struct {
	active_camera_name:      string,
	ambient_light:           AmbientLight,
	point_lights:            [MAX_POINT_LIGHTS]PointLight,
	directional_lights:      [MAX_DIRECTIONAL_LIGHTS]DirectionalLight,
	spot_lights:             [MAX_SPOT_LIGHTS]SpotLight,
	point_light_count:       u32,
	directional_light_count: u32,
	spot_light_count:        u32,
	instances:               Pool(Instance),
	selected_instance:       InstanceHandle,
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

TimeInfo :: struct {
	time:        f32,
	delta_time:  f32,
	frame_count: u32,
}

SceneData :: struct {
	view:                    Mat4x4,
	proj:                    Mat4x4,
	light_view_proj:         [MAX_SHADOW_LIGHTS][6]Mat4x4,
	dir_light_view_proj:     [MAX_SHADOW_LIGHTS]Mat4x4,
	point_lights:            [MAX_POINT_LIGHTS]PointLight,
	directional_lights:      [MAX_DIRECTIONAL_LIGHTS]DirectionalLight,
	spot_lights:             [MAX_SPOT_LIGHTS]SpotLight,
	cam_pos:                 Vec3,
	time_info:               TimeInfo,
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
	scene_data:       backend.GPUPtr(SceneData),
	vertex_buffer:    backend.GPUPtr(Vertex),
	transform_buffer: backend.GPUPtr(GpuTransform),
	instance_index:   u32,
	face_index:       u32,
	light_index:      u32,
}

DirShadowPushConstants :: struct {
	scene_data:       backend.GPUPtr(SceneData),
	vertex_buffer:    backend.GPUPtr(Vertex),
	transform_buffer: backend.GPUPtr(GpuTransform),
	instance_index:   u32,
	light_index:      u32,
}

PushConstants :: struct {
	scene_data:       backend.GPUPtr(SceneData),
	vertex_buffer:    backend.GPUPtr(Vertex),
	material_buffer:  backend.GPUPtr(GpuMaterial),
	transform_buffer: backend.GPUPtr(GpuTransform),
	material_index:   u32,
	instance_index:   u32,
}

SkyboxPushConstants :: struct {
	scene_data: backend.GPUPtr(SceneData),
}

DebugViewMode :: enum u32 {
	Texture_2D,
	Shadow_Cube_Face,
	Dir_Shadow,
}

DebugViewPushConstants :: struct {
	mode:  DebugViewMode,
	index: u32, // bindless texture index (Texture_2D) or light_index (Shadow_Cube_Face / Dir_Shadow)
	face:  u32, // cube face_index (Shadow_Cube_Face only)
}

ParticlePushConstants :: struct {
	scene_data:    backend.GPUPtr(SceneData),
	particles_in:  backend.GPUPtr(Particle),
	particles_out: backend.GPUPtr(Particle),
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
transform_to_matrix :: proc(transform: Transform) -> Mat4x4 {
	translation := linalg.matrix4_translate(transform.translation)
	rotation := linalg.matrix4_from_quaternion(transform.rotation)
	scale := linalg.matrix4_scale(transform.scale)

	return translation * rotation * scale
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

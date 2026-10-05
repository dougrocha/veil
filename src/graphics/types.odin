package graphics

import "core:math/linalg"
import "core:mem/virtual"
import "core:time"

import sdl "vendor:sdl3"

import "backend"

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

// vk.Extent2D-shaped but backend-agnostic so callers don't need to import vk.
Extent2D :: struct {
	width:  u32,
	height: u32,
}

vec3_splat :: proc(v: f32) -> Vec3 {return {v, v, v}}

App :: struct {
	window:          ^sdl.Window,
	width:           u32,
	height:          u32,
	engine:          Engine,
	last_frame_time: time.Time,
}

Engine :: struct {
	vk_ctx:             backend.Context,

	// swapchain
	swapchain:          backend.Swapchain,

	// shaders
	shader_system:      ShaderSystem,

	// graphics pipeline
	pipeline_registry:  PipelineRegistry,

	// frame and sync resources
	frame_data:         [backend.MAX_FRAMES_IN_FLIGHT]FrameData,
	frame_index:        u64,

	// buffers
	model_system:       ModelSystem,
	material_system:    MaterialSystem,

	// timers
	time_info:          TimeInfo,

	// texture
	texture_system:     TextureSystem,

	// global resources (binding 0 = point shadow cube atlas, 1 = 2D shadow atlas, 2 = skybox)
	global_descriptor:  backend.DescriptorSet,
	// bindless storage images for compute post passes; slots are the STORAGE_SLOT_* constants
	storage_descriptor: backend.DescriptorSet,
	hdr_texture:        TextureHandle, // external texture for render_targets.hdr; stable across resizes
	bloom_textures:     [backend.BLOOM_MAX_MIPS]TextureHandle, // one external texture per bloom mip
	shadow_atlas:       ShadowAtlas,
	shadow_2d_atlas:    ShadowAtlas,

	// simulation state — no Vulkan types
	scene:              Scene,
	camera_system:      CameraSystem,
	stats:              Stats,
	gpu_profiler:       GpuProfiler,
	shadow_cache:       ShadowCache,

	// debug capture
	frame_dump:         FrameDump,

	// other stuff
	line_renderer:      LineRenderer,
	ui_renderer:        UIRenderer,
	debug_views:        DebugViewQueue,
	debug_settings:     DebugSettings,

	// Temp allocator for engine_render, reset at the end of every frame. Kept apart from the
	// game loop's context.temp_allocator so each side resets on its own schedule.
	frame_arena:        virtual.Arena,
}

LightMask :: enum u32 {
	Point       = 1,
	Directional = 2,
	Spot        = 4,
}

DebugSettings :: struct {
	show_cascades, disable_shadows, light_mask: u32,
	particles:                                  bool, // CPU-only; not uploaded to the GPU
	// CPU-only bloom controls; max levels is clamped to what the bloom target was allocated with
	bloom_max_levels:                           u32,
	bloom_strength:                             f32,
}

TimeInfo :: struct {
	time, delta_time: f32,
	frame_count:      u32,
}

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
	selection:               Selection,
}

AlphaMode :: enum {
	Opaque,
	Mask,
	Blend,
}

ShadowLightType :: enum u32 {
	Directional,
	Spot,
	Point,
}

ShadowPushConstants :: struct #packed {
	scene_data:       backend.GPUPtr(SceneData),
	vertex_buffer:    backend.GPUPtr(Vertex),
	material_buffer:  backend.GPUPtr(GpuMaterial),
	transform_buffer: backend.GPUPtr(GpuTransform),
	view_proj:        Mat4x4,
	instance_index:   u32,
	light_type:       ShadowLightType,
	light_index:      u32,
	material_index:   u32,
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

UIPushConstants :: struct {
	vertex_buffer: backend.GPUPtr(UI_Vertex),
	screen_size:   Vec2,
	atlas_texture: u32, // bindless index into the texture descriptor array
}

DebugViewMode :: enum u32 {
	Texture_2D,
	Shadow_Cube_Face,
	Shadow_2D,
}

DebugViewPushConstants :: struct {
	mode:  DebugViewMode,
	index: u32, // bindless texture index (Texture_2D) or light_index (Shadow_Cube_Face / Shadow_2D)
	face:  u32, // cube face_index (Shadow_Cube_Face only)
}

TonemapPushConstants :: struct {
	hdr_texture:    u32, // bindless sampled index of the HDR image
	out_storage:    u32, // bindless storage index of the LDR draw image
	exposure:       f32,
	bloom_texture:  u32, // bindless sampled index of bloom mip 0 (half res)
	bloom_strength: f32, // pre-normalized: setting / bloom level count
}

// Shared by the bloom downsample and upsample passes.
BloomPushConstants :: struct {
	src_texture:    u32, // bindless sampled index of the mip (or hdr) being read
	dst_storage:    u32, // bindless storage index of the mip being written
	src_texel_size: Vec2, // 1 / source size, for sample offsets
	karis:          u32, // downsample only: 1 on the first pass (reading hdr)
	radius:         f32, // upsample only: tent filter radius, in source texels
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

// Splits an affine matrix back into TRS. Shear (a non-uniformly scaled parent with a rotated
// child) can't be represented and is lost.
transform_from_matrix :: proc(m: Mat4x4) -> Transform {
	x := Vec3{m[0, 0], m[1, 0], m[2, 0]}
	y := Vec3{m[0, 1], m[1, 1], m[2, 1]}
	z := Vec3{m[0, 2], m[1, 2], m[2, 2]}
	scale := Vec3{linalg.length(x), linalg.length(y), linalg.length(z)}
	if linalg.dot(linalg.cross(x, y), z) < 0 do scale.x = -scale.x // mirrored
	x /= scale.x if scale.x != 0 else 1
	y /= scale.y if scale.y != 0 else 1
	z /= scale.z if scale.z != 0 else 1
	rotation := matrix[3, 3]f32{
		x.x, y.x, z.x,
		x.y, y.y, z.y,
		x.z, y.z, z.z,
	}
	return Transform {
		translation = {m[0, 3], m[1, 3], m[2, 3]},
		rotation = linalg.quaternion_from_matrix3(rotation),
		scale = scale,
	}
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

#assert(size_of(LineVertex) == 32)
#assert(size_of(UI_Vertex) == 24)
#assert(size_of(Particle) == 48)

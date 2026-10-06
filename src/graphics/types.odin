package graphics

import "core:math/linalg"
import "core:mem/virtual"

import "backend"

PARTICLE_COUNT :: 8192

// Screen-space rect, vk.Rect2D-shaped but backend-agnostic so callers don't need to import vk.
Rect2D :: struct {
	offset: [2]i32,
	extent: [2]u32,
}

Extent2D :: backend.Extent2D

Engine :: struct {
	// renderer
	vk_ctx:            backend.Context,
	swapchain:         backend.Swapchain,
	render_targets:    RenderTargets,
	shader_system:     ShaderSystem,
	pipeline_registry: PipelineRegistry,
	frame_data:        [backend.MAX_FRAMES_IN_FLIGHT]FrameData,
	model_system:      ModelSystem,
	material_system:   MaterialSystem,
	texture_system:    TextureSystem,
	shadows:           Shadows,

	// world state
	scene:             Scene,
	camera_system:     CameraSystem,

	// runtime info
	time_info:         TimeInfo,
	stats:             Stats,

	// debug
	gpu_profiler:      GpuProfiler,
	frame_dump:        FrameDump,
	line_renderer:     LineRenderer,
	ui_renderer:       UIRenderer,
	debug_views:       DebugViewQueue,
	debug_settings:    DebugSettings,

	// Temp allocator for the engine loop, reset at the end of every frame. Kept apart from the
	// game loop's context.temp_allocator so each side resets on its own schedule.
	// TODO: make sure this is a good idea
	frame_arena:       virtual.Arena,
}

LightMask :: enum u32 {
	Point       = 1,
	Directional = 2,
	Spot        = 4,
}

DebugSettings :: struct {
	show_cascades, disable_shadows, light_mask: u32,
	particles:                                  bool, // CPU-only; not uploaded to the GPU
	show_lights:                                bool, // CPU-only; debug_lights_draw
	// CPU-only bloom controls; max levels is clamped to what the bloom target was allocated with
	bloom_max_levels:                           u32,
	bloom_strength:                             f32,
	exposure:                                   f32, // CPU-only; tonemap push constant
	post_control:                               PostControl, // which value the arrow keys adjust
}

PostControl :: enum {
	Exposure,
	Bloom_Strength,
	Bloom_Levels,
}

TimeInfo :: struct {
	time, delta_time: f32,
	frame_count:      u32,
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

// view_proj first: after an odd number of pointers Slang would pad it to 16 bytes and #packed wouldn't.
ShadowPushConstants :: struct #packed {
	view_proj:        Mat4x4,
	scene_data:       backend.GPUPtr(SceneData),
	vertex_buffer:    backend.GPUPtr(Vertex),
	material_buffer:  backend.GPUPtr(GpuMaterial),
	transform_buffer: backend.GPUPtr(GpuTransform),
	instance_ids:     backend.GPUPtr(u32), // see instancing.odin
	instance_offset:  u32,
	light_type:       ShadowLightType,
	light_index:      u32,
	material_index:   u32,
}

PushConstants :: struct {
	scene_data:       backend.GPUPtr(SceneData),
	vertex_buffer:    backend.GPUPtr(Vertex),
	material_buffer:  backend.GPUPtr(GpuMaterial),
	transform_buffer: backend.GPUPtr(GpuTransform),
	instance_ids:     backend.GPUPtr(u32), // see instancing.odin
	material_index:   u32,
	instance_offset:  u32,
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


Particle :: struct {
	position: Vec4,
	velocity: Vec4,
	color:    Vec4,
}

#assert(size_of(LineVertex) == 32)
#assert(size_of(UI_Vertex) == 24)
#assert(size_of(Particle) == 48)

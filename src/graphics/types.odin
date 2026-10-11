package graphics

import "core:mem/virtual"
import "core:time"

import "backend"

@(shader_shared)
PARTICLE_GROUP_SIZE :: 256
PARTICLE_COUNT :: 8192

// Screen-space rect, vk.Rect2D-shaped but backend-agnostic so callers don't need to import vk.
Rect2D :: struct {
	offset: [2]i32,
	extent: [2]u32,
}

Extent2D :: backend.Extent2D

// Runtime and graphics resources; world state is owned by World.
Engine :: struct {
	vk_ctx:                 backend.Context,
	swapchain:              backend.Swapchain,
	render_targets:         RenderTargets,
	shader_system:          ShaderSystem,
	pipeline_registry:      PipelineRegistry,
	frame_data:             [backend.MAX_FRAMES_IN_FLIGHT]FrameData,
	shadows:                Shadows,
	gpu_profiler:           GpuProfiler,
	frame_dump:             FrameDump,
	line_renderer:          LineRenderer,
	ui_renderer:            UIRenderer,
	debug_views:            DebugViewQueue,
	model_system:           ModelSystem,
	prev_draws:             DrawHistory,
	material_system:        MaterialSystem,
	texture_system:         TextureSystem,
	frame_count:            u32, // frames recorded
	gpu_cull_validate:      bool,
	gpu_cull_validated:     bool,
	gpu_cull_validate_slot: int,
	last_render:            time.Tick, // when engine_render last ran, for the stats frame time
	stats:                  Stats,
	config:                 EngineConfig,
	settings:               RenderSettings,
	// Scratch for engine_render, reset independently of the game loop.
	frame_arena:            virtual.Arena,
}

PresentMode :: backend.PresentMode

// Fixed for the engine's lifetime; engine_create reads it once.
EngineConfig :: struct {
	present_mode: PresentMode, // falls back to Fifo when the surface doesn't support it
}

LightTypes :: bit_set[LightType;u32] // bit n is LightType n, as debug_settings.light_mask

LIGHT_TYPES_ALL :: LightTypes{.Directional, .Spot, .Point}

// Renderer switches, changeable every frame. Plain CPU types: scene_data_buffer_update converts
// what the shaders read.
RenderSettings :: struct {
	shadows:        bool,
	lights:         LightTypes, // the types that light the scene and cast shadows
	cascade_colors: bool, // tints lighting by directional shadow cascade
	particles:      bool,
	gpu_cull:       bool,
}

RENDER_SETTINGS_DEFAULT :: RenderSettings {
	shadows  = true,
	gpu_cull = true,
	lights   = LIGHT_TYPES_ALL,
}

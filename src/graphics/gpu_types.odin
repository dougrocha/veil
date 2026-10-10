package graphics

import "backend"

// Scene-wide types shared with the shaders. Feature types live with their feature; anything
// tagged @(shader_shared) is written to shaders/types.slang by `just gpu-types`, which also
// asserts every struct's layout in gpu_layout_generated.odin.

@(shader_shared)
SAMPLER_LINEAR_REPEAT :: 0
@(shader_shared)
SAMPLER_LINEAR_CLAMP :: 1
@(shader_shared)
SAMPLER_NEAREST_CLAMP :: 2
@(shader_shared)
BINDLESS_SAMPLER_COUNT :: 3
@(shader_shared)
BINDLESS_STORAGE_IMAGE_COUNT :: 16
@(shader_shared)
BINDLESS_CUBE_COUNT :: 16

@(shader_shared)
GpuTimeInfo :: struct #max_field_align(16) {
	time:        f32,
	delta_time:  f32,
	frame_count: u32,
	_reserved:   u32,
}

@(shader_shared)
GpuDebugSettings :: struct #max_field_align(16) {
	show_cascades:   u32,
	disable_shadows: u32,
	light_mask:      u32,
	_reserved:       u32,
}

@(shader_shared)
GpuTransform :: struct #max_field_align(16) {
	model:         Mat4x4,
	normal_matrix: Mat4x4,
}

@(shader_shared)
SceneData :: struct #max_field_align(16) {
	view:                    Mat4x4,
	proj:                    Mat4x4,
	point_light_view_proj:   [MAX_POINT_SHADOW_LIGHTS][6]Mat4x4,
	shadow_2d_view_proj:     [MAX_SHADOW_2D_SLOTS]Mat4x4,
	shadow_cascade_data:     [MAX_DIRECTIONAL_LIGHTS]GpuShadowCascadeData,
	cam_pos_shadow_map_size: Vec4,
	time_info:               GpuTimeInfo,
	point_lights:            backend.GPUPtr(GpuPointLight),
	point_light_count:       u32,
	directional_light_count: u32,
	spot_light_count:        u32,
	skybox_cube:             CubeIndex, // bindless cube slot the skybox (and later IBL) samples
	_reserved_light_align:   [2]u32,
	directional_lights:      [MAX_DIRECTIONAL_LIGHTS]GpuDirectionalLight,
	spot_lights:             backend.GPUPtr(GpuSpotLight),
	_reserved_ambient_align: [2]u32,
	ambient_light:           GpuAmbientLight,
	debug_settings:          GpuDebugSettings,
}

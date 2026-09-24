package graphics

MAX_POINT_LIGHTS :: 16
MAX_DIRECTIONAL_LIGHTS :: 4
MAX_SPOT_LIGHTS :: 4
SHADOW_MAP_CASCADE_COUNT :: 4
MAX_SHADOW_2D_SLOTS :: (MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + MAX_SPOT_LIGHTS
LIGHT_MASK_POINT :: 1
LIGHT_MASK_DIRECTIONAL :: 2
LIGHT_MASK_SPOT :: 4
LIGHT_MASK_ALL :: 7
SAMPLER_LINEAR_REPEAT :: 0
SAMPLER_LINEAR_CLAMP :: 1
SAMPLER_NEAREST_CLAMP :: 2
BINDLESS_SAMPLER_COUNT :: 3

Vertex :: struct #max_field_align(16) {
	pos:     Vec3,
	_pad0:   f32,
	uv:      Vec2,
	_pad1:   Vec2,
	normal:  Vec3,
	_pad2:   f32,
	tangent: Vec4,
}

GpuAmbientLight :: struct #max_field_align(16) {
	color_brightness: Vec4,
}

GpuPointLight :: struct #max_field_align(16) {
	position_range:      Vec4,
	color_shadow_near:   Vec4,
	attenuation_diffuse: Vec4,
	specular_reserved:   Vec4,
}

GpuDirectionalLight :: struct #max_field_align(16) {
	direction_diffuse:       Vec4,
	color_specular:          Vec4,
	shadow_maximum_reserved: Vec4,
}

GpuSpotLight :: struct #max_field_align(16) {
	position_range:  Vec4,
	direction_inner: Vec4,
	color_outer:     Vec4,
	attenuation:     Vec4,
	intensity:       Vec4,
}

GpuTimeInfo :: struct #max_field_align(16) {
	time:        f32,
	delta_time:  f32,
	frame_count: u32,
	_reserved:   u32,
}

GpuDebugSettings :: struct #max_field_align(16) {
	show_cascades:   u32,
	disable_shadows: u32,
	light_mask:      u32,
	_reserved:       u32,
}

GpuShadowCascadeData :: struct #max_field_align(16) {
	split: Vec4,
	bias:  Vec4,
}

GpuTransform :: struct #max_field_align(16) {
	model:         Mat4x4,
	normal_matrix: Mat4x4,
}

GpuMaterial :: struct #max_field_align(16) {
	base_color:                 Vec4,
	perceptual_roughness:       f32,
	metallic:                   f32,
	base_color_texture:         u32,
	metallic_roughness_texture: u32,
	normal_map_texture:         u32,
	occlusion_texture:          u32,
	alpha_mode:                 u32,
	alpha_cutoff:               f32,
}

SceneData :: struct #max_field_align(16) {
	view:                    Mat4x4,
	proj:                    Mat4x4,
	point_light_view_proj:   [MAX_POINT_LIGHTS][6]Mat4x4,
	shadow_2d_view_proj:     [MAX_SHADOW_2D_SLOTS]Mat4x4,
	shadow_cascade_data:     [MAX_DIRECTIONAL_LIGHTS]ShadowCascadeData,
	cam_pos_shadow_map_size: Vec4,
	time_info:               GpuTimeInfo,
	point_lights:            [MAX_POINT_LIGHTS]GpuPointLight,
	point_light_count:       u32,
	directional_light_count: u32,
	spot_light_count:        u32,
	_reserved_counts:        u32,
	directional_lights:      [MAX_DIRECTIONAL_LIGHTS]GpuDirectionalLight,
	spot_lights:             [MAX_SPOT_LIGHTS]GpuSpotLight,
	ambient_light:           GpuAmbientLight,
	debug_settings:          GpuDebugSettings,
}

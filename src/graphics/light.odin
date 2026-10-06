package graphics

import "core:log"
import "core:math/linalg"

@(shader_shared)
MAX_POINT_LIGHTS :: 512
@(shader_shared)
MAX_DIRECTIONAL_LIGHTS :: 2
@(shader_shared)
MAX_SPOT_LIGHTS :: 32

@(shader_shared)
LightType :: enum u32 {
	Directional,
	Spot,
	Point,
}

@(shader_shared)
GpuAmbientLight :: struct #max_field_align(16) {
	color_brightness: Vec4,
}

@(shader_shared)
GpuPointLight :: struct #max_field_align(16) {
	position_range:      Vec4,
	color_shadow_near:   Vec4,
	attenuation_diffuse: Vec4,
	specular_reserved:   Vec4,
}

@(shader_shared)
GpuDirectionalLight :: struct #max_field_align(16) {
	direction_diffuse:       Vec4,
	color_specular:          Vec4,
	shadow_maximum_reserved: Vec4,
}

@(shader_shared)
GpuSpotLight :: struct #max_field_align(16) {
	position_range:  Vec4,
	direction_inner: Vec4,
	color_outer:     Vec4,
	attenuation:     Vec4,
	intensity:       Vec4,
}

// CPU world state. The renderer uploads it and caches derived shadow data separately.
LightData :: struct {
	ambient_light:           AmbientLight,
	point_lights:            [MAX_POINT_LIGHTS]PointLight,
	directional_lights:      [MAX_DIRECTIONAL_LIGHTS]DirectionalLight,
	spot_lights:             [MAX_SPOT_LIGHTS]SpotLight,
	point_light_count:       u32,
	directional_light_count: u32,
	spot_light_count:        u32,
}

AmbientLight :: struct {
	color:      Vec4,
	brightness: f32,
}

PointLight :: struct {
	pos:                                   Vec3,
	range, shadow_near:                    f32,
	color:                                 Vec3,
	constant, linear, quadratic:           f32,
	diffuse_intensity, specular_intensity: f32,
}

DirectionalLight :: struct {
	direction:                                                      Vec3,
	color:                                                          Vec3,
	diffuse_intensity, specular_intensity, shadow_maximum_distance: f32,
}

SpotLight :: struct {
	pos:                                       Vec3,
	range, shadow_near, inner_cutoff:          f32,
	direction:                                 Vec3,
	outer_cutoff, constant, linear, quadratic: f32,
	color:                                     Vec3,
	diffuse_intensity, specular_intensity:     f32,
}

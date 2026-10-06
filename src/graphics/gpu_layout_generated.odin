// Generated from the @(shader_shared) declarations in src/graphics by tools/gpu_types_gen.
// Do not edit. Holds each struct to the scalar layout Slang compiles with (see shaders.odin).
package graphics

// Every shared struct by its Slang name, for gpu_layout_check.
GPU_SHARED_TYPES := [?]GpuSharedType {
	{"Particle", Particle},
	{"ParticlePushConstants", ParticlePushConstants},
	{"DebugViewPushConstants", DebugViewPushConstants},
	{"SkyboxPushConstants", SkyboxPushConstants},
	{"TimeInfo", GpuTimeInfo},
	{"DebugSettings", GpuDebugSettings},
	{"Transform", GpuTransform},
	{"SceneData", SceneData},
	{"AmbientLight", GpuAmbientLight},
	{"PointLight", GpuPointLight},
	{"DirectionalLight", GpuDirectionalLight},
	{"SpotLight", GpuSpotLight},
	{"LineVertex", LineVertex},
	{"LinePushConstants", LinePushConstants},
	{"Material", GpuMaterial},
	{"Vertex", Vertex},
	{"MeshPushConstants", MeshPushConstants},
	{"TonemapPushConstants", TonemapPushConstants},
	{"BloomPushConstants", BloomPushConstants},
	{"ShadowCascadeData", GpuShadowCascadeData},
	{"ShadowPushConstants", ShadowPushConstants},
	{"UIVertex", UIVertex},
	{"UIPushConstants", UIPushConstants},
}

#assert(offset_of(Particle, position) == 0)
#assert(offset_of(Particle, velocity) == 16)
#assert(offset_of(Particle, color) == 32)
#assert(size_of(Particle) == 48)

#assert(offset_of(ParticlePushConstants, scene_data) == 0)
#assert(offset_of(ParticlePushConstants, particles_in) == 8)
#assert(offset_of(ParticlePushConstants, particles_out) == 16)
#assert(offset_of(ParticlePushConstants, delta_time) == 24)
#assert(size_of(ParticlePushConstants) == 32)

#assert(offset_of(DebugViewPushConstants, mode) == 0)
#assert(offset_of(DebugViewPushConstants, index) == 4)
#assert(offset_of(DebugViewPushConstants, face) == 8)
#assert(size_of(DebugViewPushConstants) == 12)

#assert(offset_of(SkyboxPushConstants, scene_data) == 0)
#assert(size_of(SkyboxPushConstants) == 8)

#assert(offset_of(GpuTimeInfo, time) == 0)
#assert(offset_of(GpuTimeInfo, delta_time) == 4)
#assert(offset_of(GpuTimeInfo, frame_count) == 8)
#assert(offset_of(GpuTimeInfo, _reserved) == 12)
#assert(size_of(GpuTimeInfo) == 16)

#assert(offset_of(GpuDebugSettings, show_cascades) == 0)
#assert(offset_of(GpuDebugSettings, disable_shadows) == 4)
#assert(offset_of(GpuDebugSettings, light_mask) == 8)
#assert(offset_of(GpuDebugSettings, _reserved) == 12)
#assert(size_of(GpuDebugSettings) == 16)

#assert(offset_of(GpuTransform, model) == 0)
#assert(offset_of(GpuTransform, normal_matrix) == 64)
#assert(size_of(GpuTransform) == 128)

#assert(offset_of(SceneData, view) == 0)
#assert(offset_of(SceneData, proj) == 64)
#assert(offset_of(SceneData, point_light_view_proj) == 128)
#assert(offset_of(SceneData, shadow_2d_view_proj) == 3200)
#assert(offset_of(SceneData, shadow_cascade_data) == 5760)
#assert(offset_of(SceneData, cam_pos_shadow_map_size) == 5824)
#assert(offset_of(SceneData, time_info) == 5840)
#assert(offset_of(SceneData, point_lights) == 5856)
#assert(offset_of(SceneData, point_light_count) == 38624)
#assert(offset_of(SceneData, directional_light_count) == 38628)
#assert(offset_of(SceneData, spot_light_count) == 38632)
#assert(offset_of(SceneData, skybox_cube) == 38636)
#assert(offset_of(SceneData, directional_lights) == 38640)
#assert(offset_of(SceneData, spot_lights) == 38736)
#assert(offset_of(SceneData, ambient_light) == 41296)
#assert(offset_of(SceneData, debug_settings) == 41312)
#assert(size_of(SceneData) == 41328)

#assert(offset_of(GpuAmbientLight, color_brightness) == 0)
#assert(size_of(GpuAmbientLight) == 16)

#assert(offset_of(GpuPointLight, position_range) == 0)
#assert(offset_of(GpuPointLight, color_shadow_near) == 16)
#assert(offset_of(GpuPointLight, attenuation_diffuse) == 32)
#assert(offset_of(GpuPointLight, specular_reserved) == 48)
#assert(size_of(GpuPointLight) == 64)

#assert(offset_of(GpuDirectionalLight, direction_diffuse) == 0)
#assert(offset_of(GpuDirectionalLight, color_specular) == 16)
#assert(offset_of(GpuDirectionalLight, shadow_maximum_reserved) == 32)
#assert(size_of(GpuDirectionalLight) == 48)

#assert(offset_of(GpuSpotLight, position_range) == 0)
#assert(offset_of(GpuSpotLight, direction_inner) == 16)
#assert(offset_of(GpuSpotLight, color_outer) == 32)
#assert(offset_of(GpuSpotLight, attenuation) == 48)
#assert(offset_of(GpuSpotLight, intensity) == 64)
#assert(size_of(GpuSpotLight) == 80)

#assert(offset_of(LineVertex, position) == 0)
#assert(offset_of(LineVertex, _pad0) == 12)
#assert(offset_of(LineVertex, color) == 16)
#assert(size_of(LineVertex) == 32)

#assert(offset_of(LinePushConstants, scene_data) == 0)
#assert(offset_of(LinePushConstants, vertex_buffer) == 8)
#assert(offset_of(LinePushConstants, screen_size) == 16)
#assert(offset_of(LinePushConstants, thickness) == 24)
#assert(size_of(LinePushConstants) == 32)

#assert(offset_of(GpuMaterial, base_color) == 0)
#assert(offset_of(GpuMaterial, emissive) == 16)
#assert(offset_of(GpuMaterial, perceptual_roughness) == 32)
#assert(offset_of(GpuMaterial, metallic) == 36)
#assert(offset_of(GpuMaterial, base_color_texture) == 40)
#assert(offset_of(GpuMaterial, metallic_roughness_texture) == 44)
#assert(offset_of(GpuMaterial, normal_map_texture) == 48)
#assert(offset_of(GpuMaterial, occlusion_texture) == 52)
#assert(offset_of(GpuMaterial, alpha_mode) == 56)
#assert(offset_of(GpuMaterial, alpha_cutoff) == 60)
#assert(offset_of(GpuMaterial, double_sided) == 64)
#assert(offset_of(GpuMaterial, _pad0) == 68)
#assert(offset_of(GpuMaterial, _pad1) == 72)
#assert(offset_of(GpuMaterial, _pad2) == 76)
#assert(size_of(GpuMaterial) == 80)

#assert(offset_of(Vertex, pos_uv_x) == 0)
#assert(offset_of(Vertex, normal_uv_y) == 16)
#assert(offset_of(Vertex, tangent) == 32)
#assert(size_of(Vertex) == 48)

#assert(offset_of(MeshPushConstants, scene_data) == 0)
#assert(offset_of(MeshPushConstants, vertex_buffer) == 8)
#assert(offset_of(MeshPushConstants, material_buffer) == 16)
#assert(offset_of(MeshPushConstants, transform_buffer) == 24)
#assert(offset_of(MeshPushConstants, instance_ids) == 32)
#assert(offset_of(MeshPushConstants, material_index) == 40)
#assert(offset_of(MeshPushConstants, instance_offset) == 44)
#assert(size_of(MeshPushConstants) == 48)

#assert(offset_of(TonemapPushConstants, hdr_texture) == 0)
#assert(offset_of(TonemapPushConstants, out_storage) == 4)
#assert(offset_of(TonemapPushConstants, exposure) == 8)
#assert(offset_of(TonemapPushConstants, bloom_texture) == 12)
#assert(offset_of(TonemapPushConstants, bloom_strength) == 16)
#assert(size_of(TonemapPushConstants) == 20)

#assert(offset_of(BloomPushConstants, src_texture) == 0)
#assert(offset_of(BloomPushConstants, dst_storage) == 4)
#assert(offset_of(BloomPushConstants, src_texel_size) == 8)
#assert(offset_of(BloomPushConstants, karis) == 16)
#assert(offset_of(BloomPushConstants, radius) == 20)
#assert(size_of(BloomPushConstants) == 24)

#assert(offset_of(GpuShadowCascadeData, split) == 0)
#assert(offset_of(GpuShadowCascadeData, bias) == 16)
#assert(size_of(GpuShadowCascadeData) == 32)

#assert(offset_of(ShadowPushConstants, view_proj) == 0)
#assert(offset_of(ShadowPushConstants, scene_data) == 64)
#assert(offset_of(ShadowPushConstants, vertex_buffer) == 72)
#assert(offset_of(ShadowPushConstants, material_buffer) == 80)
#assert(offset_of(ShadowPushConstants, transform_buffer) == 88)
#assert(offset_of(ShadowPushConstants, instance_ids) == 96)
#assert(offset_of(ShadowPushConstants, instance_offset) == 104)
#assert(offset_of(ShadowPushConstants, light_type) == 108)
#assert(offset_of(ShadowPushConstants, light_index) == 112)
#assert(offset_of(ShadowPushConstants, material_index) == 116)
#assert(size_of(ShadowPushConstants) == 120)

#assert(offset_of(UIVertex, position) == 0)
#assert(offset_of(UIVertex, uv) == 8)
#assert(offset_of(UIVertex, color) == 16)
#assert(offset_of(UIVertex, _pad0) == 20)
#assert(size_of(UIVertex) == 24)

#assert(offset_of(UIPushConstants, vertex_buffer) == 0)
#assert(offset_of(UIPushConstants, screen_size) == 8)
#assert(offset_of(UIPushConstants, atlas_texture) == 16)
#assert(size_of(UIPushConstants) == 24)

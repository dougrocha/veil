#include "bindless.slang"
import types;

struct VSInput {
    uint vertex_index : SV_VertexID;
    uint start_vertex_location : SV_StartVertexLocation;
    uint instance_id : SV_InstanceID;
    uint start_instance_location : SV_StartInstanceLocation;
};

struct VSOutput {
    float4 pos : SV_Position;
    float2 frag_uv;
    float3 frag_normal;
    float3 frag_tangent;
    float3 frag_bitangent;
    float3 frag_pos;
    nointerpolation uint material_index;
};

[shader("vertex")]
VSOutput vertex_main(VSInput input) {
    // Slang's SV_VertexID excludes the Vulkan base vertex; add SV_StartVertexLocation to restore it.
    let v = pc.vertex_buffer[input.vertex_index + input.start_vertex_location];
    // Slang lowers SV_InstanceID without the Vulkan base instance; add SV_StartInstanceLocation to restore it.
    let instance_slot = input.instance_id + input.start_instance_location;
    let packed_id = pc.instance_ids[instance_slot];
    let transform = pc.transform_buffer[packed_id >> INSTANCE_DRAW_ID_SHIFT];

    VSOutput output;
    float4 world_pos = mul(transform.model, float4(v.pos_uv_x.xyz, 1.0));
    output.frag_pos = world_pos.xyz;
    output.material_index = packed_id & INSTANCE_MATERIAL_MASK;

    output.pos = mul(pc.scene_data.proj, mul(pc.scene_data.view, world_pos));

    float3x3 normal_mat = (float3x3)transform.normal_matrix;
    float3 N            = normalize(mul(normal_mat, v.normal_uv_y.xyz));

    // Meshes without tangents (primitives, glTF without a TANGENT attribute)
    // store a zero tangent. Normalizing that yields NaN, and a NaN basis makes
    // the fragment's `length(frag_tangent) > 0` test pick the TBN path anyway,
    // which poisons the shaded normal and kills every light. Emit a zero basis
    // instead so the fragment falls back to the geometric normal.
    float3 T = float3(0.0);
    float3 B = float3(0.0);
    float3 tangent_ws = mul(normal_mat, v.tangent.xyz);
    if (dot(tangent_ws, tangent_ws) > 1e-12) {
        T = normalize(tangent_ws);
        T = T - dot(T, N) * N; // Gram-Schmidt re-orthogonalize
        if (dot(T, T) > 1e-12) {
            T = normalize(T);
            B = cross(N, T) * v.tangent.w;
        } else {
            T = float3(0.0);
        }
    }
    output.frag_normal    = N;
    output.frag_tangent   = T;
    output.frag_bitangent = B;

    output.frag_uv = float2(v.pos_uv_x.w, v.normal_uv_y.w);
    return output;
}

// TODO: replace with PBR
static const float MAX_SHININESS = 256.0;

float3 calc_base_lighting(float3 normal, float3 view_dir, float3 to_light, float diffuse_int, float specular_int, float3 color, float shininess = MAX_SHININESS, float smoothness = 1.0) {
    // measures the angle betwen the normal of the frag and the light direction
    // will always be positive
    float diffuse_factor = max(dot(normal, to_light), 0.0);
    // gets the "bounce" direction from the light, used so that if this points in the cameras direction
    // you get that specular highlight
    // float3 reflect_dir = reflect(-to_light, normal);

    float3 halfway_dir = normalize(to_light + view_dir);

    // gets the angle between the view direaction and the reflection
    float specular_factor = pow(max(dot(normal, halfway_dir), 0.0), shininess);


    return (diffuse_int * diffuse_factor + specular_int * smoothness * specular_factor) * color;
}

float calc_attenuation(float distance, float constant, float linear, float quadratic) {
    return 1.0 / (constant + linear * distance + quadratic * (distance * distance));
}

// smoothly fades to 0 at range instead of hard-clipping, avoiding a visible pop at the cutoff
float calc_range_attenuation(float distance, float range) {
    return clamp(1.0 - pow(distance / range, 4.0), 0.0, 1.0);
}

float3 calc_dir_light(DirectionalLight light, float3 normal, float3 view_dir, float shininess, float smoothness) {
    float3 to_light = normalize(-light.direction_diffuse.xyz);
    return calc_base_lighting(normal, view_dir, to_light, light.direction_diffuse.w, light.color_specular.w, light.color_specular.xyz, shininess, smoothness);
}

float3 calc_point_light(PointLight light, float3 normal, float3 view_dir, float3 frag_pos, float shininess, float smoothness) {
    float3 to_light = normalize(light.position_range.xyz - frag_pos);
    float distance = length(light.position_range.xyz - frag_pos);
    float attenuation = calc_attenuation(distance, light.attenuation_diffuse.x, light.attenuation_diffuse.y, light.attenuation_diffuse.z) * calc_range_attenuation(distance, light.position_range.w);
    float3 base_color = calc_base_lighting(normal, view_dir, to_light, light.attenuation_diffuse.w, light.specular_reserved.x, light.color_shadow_near.xyz, shininess, smoothness);
    return base_color * attenuation;
}

float3 calc_spot_light(SpotLight light, float3 normal, float3 view_dir, float3 frag_pos, float shininess, float smoothness) {
    float3 to_light = normalize(light.position_range.xyz - frag_pos);
    float theta = dot(to_light, normalize(-light.direction_inner.xyz));
    float epsilon = light.direction_inner.w - light.color_outer.w;
    float intensity = clamp((theta - light.color_outer.w) / epsilon, 0.0, 1.0);
    float distance = length(light.position_range.xyz - frag_pos);
    float attenuation = calc_attenuation(distance, light.attenuation.y, light.attenuation.z, light.attenuation.w) * calc_range_attenuation(distance, light.position_range.w);
    float3 base_color = calc_base_lighting(normal, view_dir, to_light, light.intensity.x, light.intensity.y, light.color_outer.xyz, shininess, smoothness);
    return base_color * intensity * attenuation;
}

[[vk_push_constant]] MeshPushConstants pc;
[[vk_binding(4, 0)]] SamplerCubeArrayShadow shadow_cubes;
[[vk_binding(5, 0)]] Sampler2DArrayShadow shadow_2d_maps;

float4 sample_base_color(TextureIndex texture, float2 uv) {
    return texture.get().Sample(gpu_sampler(SAMPLER_LINEAR_REPEAT), uv);
}

float4 sample_normal_map(TextureIndex texture, float2 uv) {
    return texture.get().Sample(gpu_sampler(SAMPLER_LINEAR_REPEAT), uv);
}

float4 sample_metallic_roughness(TextureIndex texture, float2 uv) {
    return texture.get().Sample(gpu_sampler(SAMPLER_LINEAR_REPEAT), uv);
}

float4 sample_occlusion(TextureIndex texture, float2 uv) {
    return texture.get().Sample(gpu_sampler(SAMPLER_LINEAR_REPEAT), uv);
}

// Normal offset bias: move the lookup point along the geometric normal by about one shadow texel,
// measured in world units at the fragment's distance. A fixed depth bias can't cover a texel that
// grows with distance and view angle, which shows as stripes (acne) on lit faces.
static const float NORMAL_OFFSET_TEXELS = 1.5;

float3 normal_offset(float3 frag_pos, float3 geo_normal, float3 to_light, float texel_world) {
    float slope = saturate(1.0 - dot(geo_normal, to_light)); // grazing light needs more
    return frag_pos + geo_normal * texel_world * NORMAL_OFFSET_TEXELS * (0.5 + slope);
}

float calc_point_shadow_factor(PointLight light, uint light_index, float3 frag_pos, float3 normal) {
    if (light_index >= MAX_POINT_SHADOW_LIGHTS) return 1.0;
    float3 light_pos = light.position_range.xyz;
    // A 90 degree cube face: one texel spans 2 * distance / face size.
    float texel_world = 2.0 * length(frag_pos - light_pos) / POINT_SHADOW_MAP_SIZE;
    frag_pos = normal_offset(frag_pos, normal, normalize(light_pos - frag_pos), texel_world);
    float3 light_to_frag = frag_pos - light_pos;
    float current_depth = length(light_to_frag) / light.position_range.w;

    float3 light_dir = normalize(light_to_frag);
    float bias = max(0.005 * (1.0 - dot(normal, -light_dir)), 0.0005);

    return shadow_cubes.SampleCmp(float4(light_to_frag, float(light_index)), current_depth - bias);
}

// dynamic (runtime-index) subscript into a float4 isn't reliable here; select via compile-time swizzles instead
float select_component(float4 v, uint idx) {
    if (idx == 0) return v.x;
    if (idx == 1) return v.y;
    if (idx == 2) return v.z;
    return v.w;
}

// The y-flip is already in the light's projection matrix (see math.odin).
float2 shadow_uv_from_ndc(float2 ndc) {
    return ndc * 0.5 + 0.5;
}

bool outside_shadow_map(float2 uv, float depth) {
    return any(uv < 0.0) || any(uv > 1.0) || depth < 0.0 || depth > 1.0;
}

float sample_cascade(float3 frag_pos, float3 normal, float3 to_light, uint light_index, uint cascade) {
    uint slot = light_index * SHADOW_MAP_CASCADE_COUNT + cascade;

    float4 light_space_pos = mul(pc.scene_data.shadow_2d_view_proj[slot], float4(frag_pos, 1.0));
    float3 proj_coords = light_space_pos.xyz / light_space_pos.w;
    proj_coords.xy = shadow_uv_from_ndc(proj_coords.xy);

    // Clamp-to-edge is useful for filtering, but must not turn geometry outside
    // a cascade into a repeated edge shadow.
    if (outside_shadow_map(proj_coords.xy, proj_coords.z)) return 1.0;

    float cascade_bias = select_component(pc.scene_data.shadow_cascade_data[light_index].bias, cascade);
    float bias = max(cascade_bias * (1.0 - dot(normal, to_light)), cascade_bias * 0.1);

    float half_texel = 0.5 / pc.scene_data.cam_pos_shadow_map_size.w;
    float depth = proj_coords.z - bias;
    // Each compare tap is already bilinear, so four taps at half-texel offsets give a 2-texel box
    // over a 3x3 texel footprint (penumbra ~30% narrower than the old 9-tap grid). Kept as explicit
    // taps: a loop form of the same pattern measured slower.
    float shadow = shadow_2d_maps.SampleCmp(
        float3(proj_coords.xy + float2(-half_texel, -half_texel), float(slot)), depth);
    shadow += shadow_2d_maps.SampleCmp(
        float3(proj_coords.xy + float2(-half_texel, half_texel), float(slot)), depth);
    shadow += shadow_2d_maps.SampleCmp(
        float3(proj_coords.xy + float2(half_texel, -half_texel), float(slot)), depth);
    shadow += shadow_2d_maps.SampleCmp(
        float3(proj_coords.xy + float2(half_texel, half_texel), float(slot)), depth);
    return shadow * 0.25;
}

float calc_dir_shadow_factor(float3 frag_pos, float3 normal, float3 to_light, uint light_index, out uint cascade_out) {
    // view space in this engine looks down -Z, so distance from the camera is -view_z
    float view_depth = -mul(pc.scene_data.view, float4(frag_pos, 1.0)).z;

    float4 splits = pc.scene_data.shadow_cascade_data[light_index].split;
    uint cascade = SHADOW_MAP_CASCADE_COUNT;
    if (view_depth < splits.x) cascade = 0;
    else if (view_depth < splits.y) cascade = 1;
    else if (view_depth < splits.z) cascade = 2;
    else if (view_depth < splits.w) cascade = 3;

    cascade_out = cascade;

    // fragment is beyond the last cascade split; leave it unshadowed rather than sampling garbage
    if (cascade == SHADOW_MAP_CASCADE_COUNT) return 1.0;

    return sample_cascade(frag_pos, normal, to_light, light_index, cascade);
}

uint spot_shadow_slot(uint light_index) {
    return (MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + light_index;
}

float calc_spot_shadow_factor(SpotLight light, uint slot, float3 frag_pos, float3 normal, float3 geo_normal, float3 to_light) {
    // The view spans 2 * tan(half angle) * distance; color_outer.w is cos(half angle).
    float cos_outer = clamp(light.color_outer.w, 0.01, 0.9999);
    float tan_outer = sqrt(1.0 - cos_outer * cos_outer) / cos_outer;
    float texel_world = 2.0 * tan_outer * length(frag_pos - light.position_range.xyz) / pc.scene_data.cam_pos_shadow_map_size.w;
    frag_pos = normal_offset(frag_pos, geo_normal, to_light, texel_world);
    float4 light_space_pos = mul(pc.scene_data.shadow_2d_view_proj[slot], float4(frag_pos, 1.0));
    float3 proj_coords = light_space_pos.xyz / light_space_pos.w;
    float2 uv = shadow_uv_from_ndc(proj_coords.xy);

    float current_depth = length(frag_pos - light.position_range.xyz) / light.position_range.w;

    if (light_space_pos.w <= 0.0 || outside_shadow_map(uv, current_depth)) return 1.0;

    float bias = max(0.005 * (1.0 - dot(normal, to_light)), 0.0005);
    return shadow_2d_maps.SampleCmp(float3(uv, float(slot)), current_depth - bias);
}

// Split so fragment_masked can discard between sampling and lighting while fragment_main has no
// discard in its call graph. Any OpKill in the module can keep early depth off for the opaque
// pipeline, and a bool flag does not fold away in the emitted SPIR-V.
struct MeshSurface {
    float4 tex_color;
    float3 normal;
    float ao;
    float smoothness;
    float shininess;
};

// Every texture sample. Implicit-LOD samples need quad derivatives, so they all run before any discard.
MeshSurface sample_mesh_surface(VSOutput vert, bool is_front) {
    let mat = pc.material_buffer[vert.material_index];

    // Double-sided back faces are lit as if they faced the viewer (only those pipelines skip culling).
    float3 geo_normal = (mat.double_sided != 0 && !is_front) ? -vert.frag_normal : vert.frag_normal;

    float4 tex_color = sample_base_color(mat.base_color_texture, vert.frag_uv) * mat.base_color;

    float3 normal;
    if (length(vert.frag_tangent) > 0.001) {
        float3x3 TBN = float3x3(vert.frag_tangent, vert.frag_bitangent, geo_normal);
        float3 normal_sample = sample_normal_map(mat.normal_map_texture, vert.frag_uv).rgb;
        normal_sample.g = 1.0 - normal_sample.g; // convert OpenGL (nor_gl) to Vulkan/DX convention
        normal = normalize(mul(normal_sample * 2.0 - 1.0, TBN));
    } else {
        normal = normalize(geo_normal);
    }

    float4 arm = sample_metallic_roughness(mat.metallic_roughness_texture, vert.frag_uv);
    float roughness = clamp(arm.g * mat.perceptual_roughness, 0.089, 1.0);
    float metallic  = arm.b * mat.metallic;
    float smoothness = 1.0 - roughness;
    float shininess = max(MAX_SHININESS * smoothness * smoothness, 1.0);

    float ao = sample_occlusion(mat.occlusion_texture, vert.frag_uv).r;

    return {tex_color, normal, ao, smoothness, shininess};
}

// Range attenuation clamp(1 - pow(d/r, 4), 0, 1) is exactly zero at d >= range.
bool point_light_out_of_range(PointLight light, float3 frag_pos) {
    return length(light.position_range.xyz - frag_pos) >= light.position_range.w;
}

// Cone intensity is exactly zero at theta <= outer; inner > outer preserves reversed or equal cutoffs.
bool spot_light_out_of_range(SpotLight light, float3 frag_pos) {
    if (length(light.position_range.xyz - frag_pos) >= light.position_range.w) return true;
    float3 to_light = normalize(light.position_range.xyz - frag_pos);
    float theta = dot(to_light, normalize(-light.direction_inner.xyz));
    float inner = light.direction_inner.w;
    float outer = light.color_outer.w;
    return inner > outer && theta <= outer;
}

// Lighting only. Material textures are read in sample_mesh_surface; the shadow lookups here run after the masked discard.
float4 light_mesh_surface(VSOutput vert, MeshSurface surf) {
    let mat = pc.material_buffer[vert.material_index];
    float4 tex_color = surf.tex_color;
    float3 normal = surf.normal;
    float smoothness = surf.smoothness;
    float shininess = surf.shininess;
    float ao = surf.ao;
    float3 view_dir = normalize(pc.scene_data.cam_pos_shadow_map_size.xyz - vert.frag_pos);

    float3 total_light = pc.scene_data.ambient_light.color_brightness.rgb * pc.scene_data.ambient_light.color_brightness.w * ao;

    static const float3 CASCADE_DEBUG_COLORS[5] = {
        float3(1.0, 0.0, 0.0), // cascade 0
        float3(0.0, 1.0, 0.0), // cascade 1
        float3(0.0, 0.0, 1.0), // cascade 2
        float3(1.0, 1.0, 0.0), // cascade 3
        float3(1.0, 1.0, 1.0), // past last split, unshadowed
    };
    float3 cascade_tint = float3(1.0, 1.0, 1.0);
    bool shadows_disabled = pc.scene_data.debug_settings.disable_shadows != 0;
    uint light_mask = pc.scene_data.debug_settings.light_mask;

    for (uint i = 0; i < ((light_mask & (1u << LIGHT_TYPE_DIRECTIONAL)) != 0 ? pc.scene_data.directional_light_count : 0); i++) {
        float3 to_light = normalize(-pc.scene_data.directional_lights[i].direction_diffuse.xyz);
        uint cascade = SHADOW_MAP_CASCADE_COUNT; // 'past last split' tint when shadows are bypassed
        float shadow = shadows_disabled ? 1.0 : calc_dir_shadow_factor(vert.frag_pos, normal, to_light, i, cascade);
        total_light += calc_dir_light(pc.scene_data.directional_lights[i], normal, view_dir, shininess, smoothness) * shadow;
        if (i == 0) cascade_tint = CASCADE_DEBUG_COLORS[cascade];
    }

    if (pc.scene_data.debug_settings.show_cascades != 0) total_light *= cascade_tint;

    bool use_cluster_list = pc.scene_data.debug_settings.clustered_lighting != 0;
    if (use_cluster_list) {
        float3 view_pos = mul(pc.scene_data.view, float4(vert.frag_pos, 1.0)).xyz;
        float4x4 proj = pc.scene_data.proj;
        bool ortho = abs(proj[3][2]) < 1e-6;
        float sign_z = proj[3][2] < 0.0 || (ortho && proj[2][2] < 0.0) ? -1.0 : 1.0;
        float view_depth = view_pos.z * sign_z;
        uint x = min(uint(floor(vert.pos.x / pc.scene_data.cluster_extent.x * float(CLUSTER_X))), CLUSTER_X - 1);
        uint y = min(uint(floor(vert.pos.y / pc.scene_data.cluster_extent.y * float(CLUSTER_Y))), CLUSTER_Y - 1);
        float near_z = pc.scene_data.cluster_near_far.x;
        float far_z = pc.scene_data.cluster_near_far.y;
        uint z = uint(clamp(floor(log(view_depth / near_z) / log(far_z / near_z) * float(CLUSTER_Z)), 0.0, float(CLUSTER_Z - 1)));
        uint cluster = x + y * CLUSTER_X + z * CLUSTER_X * CLUSTER_Y;
        ClusterHeader header = pc.scene_data.cluster_headers[cluster];
        use_cluster_list = (header.light_count & CLUSTER_OVERFLOW_BIT) == 0;
        for (uint i = 0; use_cluster_list && i < header.light_count; ++i) {
            uint light_index = pc.scene_data.cluster_indices[header.light_offset + i];
            if (light_index < MAX_POINT_LIGHTS) {
                if ((light_mask & (1u << LIGHT_TYPE_POINT)) == 0 || light_index >= pc.scene_data.point_light_count) continue;
                if (point_light_out_of_range(pc.scene_data.point_lights[light_index], vert.frag_pos)) continue;
                float shadow = shadows_disabled ? 1.0 : calc_point_shadow_factor(pc.scene_data.point_lights[light_index], light_index, vert.frag_pos, normalize(vert.frag_normal));
                total_light += calc_point_light(pc.scene_data.point_lights[light_index], normal, view_dir, vert.frag_pos, shininess, smoothness) * shadow;
            } else {
                uint spot_index = light_index - MAX_POINT_LIGHTS;
                if ((light_mask & (1u << LIGHT_TYPE_SPOT)) == 0 || spot_index >= pc.scene_data.spot_light_count) continue;
                if (spot_light_out_of_range(pc.scene_data.spot_lights[spot_index], vert.frag_pos)) continue;
                float3 to_light = normalize(pc.scene_data.spot_lights[spot_index].position_range.xyz - vert.frag_pos);
                float shadow = shadows_disabled ? 1.0 : calc_spot_shadow_factor(pc.scene_data.spot_lights[spot_index], spot_shadow_slot(spot_index), vert.frag_pos, normal, normalize(vert.frag_normal), to_light);
                total_light += calc_spot_light(pc.scene_data.spot_lights[spot_index], normal, view_dir, vert.frag_pos, shininess, smoothness) * shadow;
            }
        }
    }
    if (!use_cluster_list) {
        for (uint i = 0; i < ((light_mask & (1u << LIGHT_TYPE_POINT)) != 0 ? pc.scene_data.point_light_count : 0); i++) {
            if (point_light_out_of_range(pc.scene_data.point_lights[i], vert.frag_pos)) continue;
            float shadow = shadows_disabled ? 1.0 : calc_point_shadow_factor(pc.scene_data.point_lights[i], i, vert.frag_pos, normalize(vert.frag_normal));
            total_light += calc_point_light(pc.scene_data.point_lights[i], normal, view_dir, vert.frag_pos, shininess, smoothness) * shadow;
        }

        for (uint i = 0; i < ((light_mask & (1u << LIGHT_TYPE_SPOT)) != 0 ? pc.scene_data.spot_light_count : 0); i++) {
            if (spot_light_out_of_range(pc.scene_data.spot_lights[i], vert.frag_pos)) continue;
            float3 to_light = normalize(pc.scene_data.spot_lights[i].position_range.xyz - vert.frag_pos);
            float shadow = shadows_disabled ? 1.0 : calc_spot_shadow_factor(pc.scene_data.spot_lights[i], spot_shadow_slot(i), vert.frag_pos, normal, normalize(vert.frag_normal), to_light);
            total_light += calc_spot_light(pc.scene_data.spot_lights[i], normal, view_dir, vert.frag_pos, shininess, smoothness) * shadow;
        }
    }

    // 0 = opaque, 1 = mask, 2 = blend; matches AlphaMode in Odin.
    float output_alpha = mat.alpha_mode == ALPHA_MODE_BLEND ? tex_color.a : 1.0;
    // Emission is light the surface gives off itself, so no lighting, shadow, AO or albedo scales it.
    float3 color = tex_color.rgb * total_light + mat.emissive.rgb;
    return float4(color, output_alpha);
}

[shader("fragment")]
float4 fragment_main(VSOutput vert, bool is_front : SV_IsFrontFace) : SV_TARGET {
    return light_mesh_surface(vert, sample_mesh_surface(vert, is_front));
}

[shader("fragment")]
float4 fragment_masked(VSOutput vert, bool is_front : SV_IsFrontFace) : SV_TARGET {
    MeshSurface surf = sample_mesh_surface(vert, is_front);
    let mat = pc.material_buffer[vert.material_index];
    // Masked texels skip lighting. Runs after every implicit-LOD sample in sample_mesh_surface.
    if (mat.alpha_mode == ALPHA_MODE_MASK && surf.tex_color.a < mat.alpha_cutoff) discard;
    return light_mesh_surface(vert, surf);
}

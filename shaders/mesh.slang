import types;

struct PushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Material* material_buffer;
    Transform* transform_buffer;
    uint material_index;
    uint instance_index;
};
[[vk_push_constant]] PushConstants pc;

struct VSInput {
    uint vertex_index : SV_VertexID;
};

struct VSOutput {
    float4 pos : SV_Position;
    float2 frag_uv;
    float3 frag_normal;
    float3 frag_tangent;
    float3 frag_bitangent;
    float3 frag_pos;
};

[shader("vertex")]
VSOutput vertex_main(VSInput input) {
    let v = pc.vertex_buffer[input.vertex_index];
    let transform = pc.transform_buffer[pc.instance_index];

    VSOutput output;
    float4 world_pos = mul(transform.model, float4(v.pos, 1.0));
    output.frag_pos = world_pos.xyz;

    output.pos = mul(pc.scene_data.proj, mul(pc.scene_data.view, world_pos));

    float3x3 normal_mat = (float3x3)transform.normal_matrix;
    float3 N            = normalize(mul(normal_mat, v.normal));
    float3 T            = normalize(mul(normal_mat, v.tangent.xyz));
    T                   = normalize(T - dot(T, N) * N); // Gram-Schmidt re-orthogonalize
    float3 B            = cross(N, T) * v.tangent.w;
    output.frag_normal    = N;
    output.frag_tangent   = T;
    output.frag_bitangent = B;

    output.frag_uv = v.uv;
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

float3 calc_dir_light(DirectionalLight light, float3 normal, float3 view_dir, float shininess, float smoothness) {
    float3 to_light = normalize(-light.direction);
    return calc_base_lighting(normal, view_dir, to_light, light.diffuse_intensity, light.specular_intensity, light.color, shininess, smoothness);
}

float3 calc_point_light(PointLight light, float3 normal, float3 view_dir, float3 frag_pos, float shininess, float smoothness) {
    float3 to_light = normalize(light.pos - frag_pos);
    float distance = length(light.pos - frag_pos);
    float attenuation = calc_attenuation(distance, light.constant, light.linear, light.quadratic);
    float3 base_color = calc_base_lighting(normal, view_dir, to_light, light.diffuse_intensity, light.specular_intensity, light.color, shininess, smoothness);
    return base_color * attenuation;
}

float3 calc_spot_light(SpotLight light, float3 normal, float3 view_dir, float3 frag_pos, float shininess, float smoothness) {
    float3 to_light = normalize(light.pos - frag_pos);
    float theta = dot(to_light, normalize(-light.direction));
    float epsilon = light.inner_cutoff - light.outer_cutoff;
    float intensity = clamp((theta - light.outer_cutoff) / epsilon, 0.0, 1.0);
    float distance = length(light.pos - frag_pos);
    float attenuation = calc_attenuation(distance, light.constant, light.linear, light.quadratic);
    float3 base_color = calc_base_lighting(normal, view_dir, to_light, light.diffuse_intensity, light.specular_intensity, light.color, shininess, smoothness);
    return base_color * intensity * attenuation;
}

[[vk_binding(0, 0)]] Sampler2D textures[];
[[vk_binding(0, 1)]] SamplerCubeArrayShadow shadow_cubes;
[[vk_binding(1, 1)]] Sampler2DArrayShadow shadow_2d_maps;

float calc_point_shadow_factor(float3 frag_pos, float3 light_pos, float3 normal, uint light_index) {
    float3 light_to_frag = frag_pos - light_pos;
    float current_depth = length(light_to_frag) / pc.scene_data.shadow_far;

    float3 light_dir = normalize(light_to_frag);
    float bias = max(0.005 * (1.0 - dot(normal, -light_dir)), 0.0005);

    return shadow_cubes.SampleCmp(float4(light_to_frag, float(light_index)), current_depth - bias);
}

float calc_dir_shadow_factor(float3 frag_pos, float3 normal, float3 to_light, uint slot) {
    float4 light_space_pos = mul(pc.scene_data.shadow_2d_view_proj[slot], float4(frag_pos, 1.0));
    float3 proj_coords = light_space_pos.xyz / light_space_pos.w;
    proj_coords.xy = proj_coords.xy * 0.5 + 0.5;

    float bias = max(0.005 * (1.0 - dot(normal, to_light)), 0.0005);

    return shadow_2d_maps.SampleCmp(float3(proj_coords.xy, float(slot)), proj_coords.z - bias);
}

float calc_spot_shadow_factor(float3 frag_pos, float3 normal, float3 to_light, uint light_index) {
    uint slot = MAX_DIRECTIONAL_LIGHTS + light_index;

    // projection is now only used to find WHERE to sample...
    float4 light_space_pos = mul(pc.scene_data.shadow_2d_view_proj[slot], float4(frag_pos, 1.0));
    float2 uv = (light_space_pos.xy / light_space_pos.w) * 0.5 + 0.5;

    // while the compared value is linear distance, same as the cube path
    float3 light_pos = pc.scene_data.spot_lights[light_index].pos;
    float current_depth = length(frag_pos - light_pos) / pc.scene_data.shadow_far;

    float bias = max(0.005 * (1.0 - dot(normal, to_light)), 0.0005);
    return shadow_2d_maps.SampleCmp(float3(uv, float(slot)), current_depth - bias);
}

[shader("fragment")]
float4 fragment_main(VSOutput vert) : SV_TARGET {
    let mat = pc.material_buffer[pc.material_index];

    float4 tex_color = textures[mat.base_color_texture].Sample(vert.frag_uv) * mat.base_color;

    float3 normal;
    if (length(vert.frag_tangent) > 0.001) {
        float3x3 TBN = float3x3(vert.frag_tangent, vert.frag_bitangent, vert.frag_normal);
        float3 normal_sample = textures[mat.normal_map_texture].Sample(vert.frag_uv).rgb;
        normal_sample.g = 1.0 - normal_sample.g; // convert OpenGL (nor_gl) to Vulkan/DX convention
        normal = normalize(mul(normal_sample * 2.0 - 1.0, TBN));
    } else {
        normal = normalize(vert.frag_normal);
    }

    float4 arm = textures[mat.metallic_roughness_texture].Sample(vert.frag_uv);
    float roughness = clamp(arm.g * mat.perceptual_roughness, 0.089, 1.0);
    float metallic  = arm.b * mat.metallic;
    float smoothness = 1.0 - roughness;
    float shininess = max(MAX_SHININESS * smoothness * smoothness, 1.0);

    float3 view_dir = normalize(pc.scene_data.cam_pos - vert.frag_pos);

    float ao = textures[mat.occlusion_texture].Sample(vert.frag_uv).r;
    float3 total_light = pc.scene_data.ambient_light.color.rgb * pc.scene_data.ambient_light.brightness * ao;
    for (uint i = 0; i < pc.scene_data.directional_light_count; i++) {
        float3 to_light = normalize(-pc.scene_data.directional_lights[i].direction);
        float shadow = calc_dir_shadow_factor(vert.frag_pos, normal, to_light, i);
        total_light += calc_dir_light(pc.scene_data.directional_lights[i], normal, view_dir, shininess, smoothness) * shadow;
    }

    for (uint i = 0; i < pc.scene_data.point_light_count; i++) {
        float shadow = calc_point_shadow_factor(vert.frag_pos, pc.scene_data.point_lights[i].pos, normalize(vert.frag_normal), i);
        total_light += calc_point_light(pc.scene_data.point_lights[i], normal, view_dir, vert.frag_pos, shininess, smoothness) * shadow;
    }

    for (uint i = 0; i < pc.scene_data.spot_light_count; i++) {
        float3 to_light = normalize(pc.scene_data.spot_lights[i].pos - vert.frag_pos);
        float shadow = calc_spot_shadow_factor(vert.frag_pos, normal, to_light, i);
        total_light += calc_spot_light(pc.scene_data.spot_lights[i], normal, view_dir, vert.frag_pos, shininess, smoothness) * shadow;
    }

    if (tex_color.a < 0.1) discard;
    return float4(tex_color.rgb * total_light, tex_color.a);
}

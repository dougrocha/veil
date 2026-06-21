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
    float3 frag_color;
    float2 frag_uv;
    float3 frag_normal;
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

    output.frag_normal = mul((float3x3)transform.normal_matrix, v.normal);

    output.frag_color = v.color;
    output.frag_uv = v.uv;
    return output;
}

Sampler2D textures[];

// TODO: eventually this will be part of PBR
static const float shininess = 128;

float3 calc_base_lighting(float3 normal, float3 view_dir, float3 to_light, float diffuse_int, float specular_int, float3 color) {
    // measures the angle betwen the normal of the frag and the light direction
    // will always be positive
    float diffuse_factor = max(dot(normal, to_light), 0.0);
    // gets the "bounce" direction from the light, used so that if this points in the cameras direction
    // you get that specular highlight
    float3 reflect_dir = reflect(-to_light, normal);
    // gets the angle between the view direaction and the reflection
    float specular_factor = pow(max(dot(view_dir, reflect_dir), 0.0), shininess);

    return (diffuse_int * diffuse_factor + specular_int * specular_factor) * color;
}

float calc_attenuation(float distance, float constant, float linear, float quadratic) {
    return 1.0 / (constant + linear * distance + quadratic * (distance * distance));
}

float3 calc_dir_light(DirectionalLight light, float3 normal, float3 view_dir) {
    // light direction from the frag to the light
    float3 to_light = normalize(-light.direction);

    float3 base_color = calc_base_lighting(normal, view_dir, to_light, light.diffuse_intensity, light.specular_intensity, light.color);

    return base_color;
}

float3 calc_point_light(PointLight light, float3 normal, float3 view_dir, float3 frag_pos) {
    // get distance from light to the frag, this is because a point light acts as a normal light,
    // where as directional_light is more like the sun in the sky, rather than a lamp
    float3 to_light = normalize(light.pos - frag_pos);

    // get the absolute distnace from the two points, euclidean by default
    float distance = length(light.pos - frag_pos);
    // 1 / (some math??), pretty much the bigger the denominator the further away you are, also determined by how the light acts
    float attenuation = calc_attenuation(distance, light.constant, light.linear, light.quadratic);
    float3 base_color = calc_base_lighting(normal, view_dir, to_light, light.diffuse_intensity, light.specular_intensity, light.color);

    return base_color  * attenuation;
}

float3 calc_spot_light(SpotLight light, float3 normal, float3 view_dir, float3 frag_pos) {
    // same as point light
    float3 to_light = normalize(light.pos - frag_pos);
    // angle between where the light is pointing and the frag position
    // this will be our cutoff angle
    float theta = dot(to_light, normalize(-light.direction));
    // gets the angle of the soft edge zone
    float epsilon = light.inner_cutoff - light.outer_cutoff;
    // calculate the intensity of the light, if in inner ring its clamped to one
    // if outside the outer ring, its clamped to 0,
    // otherwise calculate the light intensity
    float intensity = clamp((theta - light.outer_cutoff) / epsilon, 0.0, 1.0);

    float distance = length(light.pos - frag_pos);
    float attenuation = calc_attenuation(distance, light.constant, light.linear, light.quadratic);

    float3 base_color = calc_base_lighting(normal, view_dir, to_light, light.diffuse_intensity, light.specular_intensity, light.color);

    return base_color * intensity * attenuation;
}

[shader("fragment")]
float4 fragment_main(VSOutput vert) : SV_TARGET {
    let mat = pc.material_buffer[pc.material_index];
    float4 tex_color = textures[mat.base_color_texture].Sample(vert.frag_uv) * float4(vert.frag_color, 1.0) * mat.base_color;

    float3 normal = normalize(vert.frag_normal);
    float3 view_dir = normalize(pc.scene_data.cam_pos - vert.frag_pos);

    float3 total_light = pc.scene_data.ambient_light.color.rgb * pc.scene_data.ambient_light.brightness;
    for (uint i = 0; i < pc.scene_data.directional_light_count; i++)
        total_light += calc_dir_light(pc.scene_data.directional_lights[i], normal, view_dir);

    for (uint i = 0; i < pc.scene_data.point_light_count; i++)
        total_light += calc_point_light(pc.scene_data.point_lights[i], normal, view_dir, vert.frag_pos);

    for (uint i = 0; i < pc.scene_data.spot_light_count; i++)
        total_light += calc_spot_light(pc.scene_data.spot_lights[i], normal, view_dir, vert.frag_pos);

    if (tex_color.a < 0.1) discard;
    return float4(total_light * tex_color.rgb, tex_color.a);
}

struct Vertex {
    float3 pos;
    float2 uv;
    float3 color;
    float3 normal;
};

struct AmbientLight {
    float4 color;
    float brightness;
};

struct PointLight {
    float3 pos;
    float constant;
    float3 color;
    float linear;
    float quadratic;
};

struct DirectionalLight {
    float3 direction;
    float3 color;
};

struct SpotLight {
    float3 pos;
    float inner_cutoff;
    float3 direction;
    float outer_cutoff;
    float3 color;
    float constant;
    float linear;
    float quadratic;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    PointLight point_lights[16];
    DirectionalLight directional_lights[4];
    SpotLight spot_lights[4];
    float3 cam_pos;
    float delta_time;
    AmbientLight ambient_light;
    uint point_light_count;
    uint directional_light_count;
    uint spot_light_count;
};

struct Material {
    float4 base_color;
    uint base_color_texture;
    // for PBR RENDERING LATER, we are doing phong for now
    // float metallic;
    // float roughness;
    // float3 emissive;
    // uint metallic_texture;
    // uint normal_texture;
    // uint roughness_texture;
    // uint emissive_texture;
};

struct Particle {
    float2 position;
    float2 velocity;
    float4 color;
};

struct PushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Material* material_buffer;
    float4x4* transform_buffer;
    uint material_index;
    uint instance_index;
};
[[vk_push_constant]] PushConstants pc;

struct VSInput {
    uint vertex_index : SV_VertexID;
};

struct VSOutput {
    float4 pos : SV_Position;
    float3 fragColor;
    float2 fragUV;
    float3 fragNormal;
    float3 fragPos;
};

[shader("vertex")]
VSOutput vertex_main(VSInput input) {
    let v = pc.vertex_buffer[input.vertex_index];
    let model = pc.transform_buffer[pc.instance_index];

    VSOutput output;
    float4 worldPos = mul(model, float4(v.pos, 1.0));
    output.fragPos = worldPos.xyz;

    output.pos = mul(pc.scene_data.proj, mul(pc.scene_data.view, worldPos));

    output.fragNormal = mul((float3x3)model, v.normal);

    output.fragColor = v.color;
    output.fragUV = v.uv;
    return output;
}

Sampler2D textures[];

static const float shininess = 128;

float3 calc_dir_light(DirectionalLight light, float3 norm, float3 viewDir) {
    float3 lightDir = normalize(-light.direction);
    float diff = max(dot(norm, lightDir), 0.0);
    float3 reflectDir = reflect(-lightDir, norm);
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), shininess);
    return (0.3 * diff + 0.1 * spec) * light.color;
}

float3 calc_point_light(PointLight light, float3 norm, float3 viewDir, float3 fragPos) {
    float3 lightDir = normalize(light.pos - fragPos);
    float diff = max(dot(norm, lightDir), 0.0);
    float3 reflectDir = reflect(-lightDir, norm);
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), shininess);
    float distance = length(light.pos - fragPos);
    float attenuation = 1.0 / (light.constant + light.linear * distance + light.quadratic * (distance * distance));
    return (diff * light.color + 0.5 * spec * light.color) * attenuation;
}

float3 calc_spot_light(SpotLight light, float3 norm, float3 viewDir, float3 fragPos) {
    float3 lightDir = normalize(light.pos - fragPos);
    float theta = dot(lightDir, normalize(-light.direction));
    float epsilon = light.inner_cutoff - light.outer_cutoff;
    float intensity = clamp((theta - light.outer_cutoff) / epsilon, 0.0, 1.0);
    float diff = max(dot(norm, lightDir), 0.0);
    float3 reflectDir = reflect(-lightDir, norm);
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), shininess);
    float distance = length(light.pos - fragPos);
    float attenuation = 1.0 / (light.constant + light.linear * distance + light.quadratic * (distance * distance));
    return (diff * light.color + 0.5 * spec * light.color) * intensity * attenuation;
}

[shader("fragment")]
float4 fragment_main(VSOutput vertIn) : SV_TARGET {
    let mat = pc.material_buffer[pc.material_index];
    float4 texColor = textures[mat.base_color_texture].Sample(vertIn.fragUV) * float4(vertIn.fragColor, 1.0) * mat.base_color;

    float3 norm = normalize(vertIn.fragNormal);
    float3 viewDir = normalize(pc.scene_data.cam_pos - vertIn.fragPos);

    float3 ambient = pc.scene_data.ambient_light.color.rgb * pc.scene_data.ambient_light.brightness;
    float3 result = ambient;
    for (uint i = 0; i < pc.scene_data.directional_light_count; i++)
        result += calc_dir_light(pc.scene_data.directional_lights[i], norm, viewDir);
    for (uint i = 0; i < pc.scene_data.point_light_count; i++)
        result += calc_point_light(pc.scene_data.point_lights[i], norm, viewDir, vertIn.fragPos);
    for (uint i = 0; i < pc.scene_data.spot_light_count; i++)
        result += calc_spot_light(pc.scene_data.spot_lights[i], norm, viewDir, vertIn.fragPos);

    return float4(result * texColor.rgb, texColor.a);
}

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
    float3 color;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    PointLight point_light;
    float3 cam_pos;
    float delta_time;
    AmbientLight ambient_light;
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

[shader("fragment")]
float4 fragment_main(VSOutput vertIn) : SV_TARGET {
    // material
    let mat = pc.material_buffer[pc.material_index];
    float4 texColor = textures[mat.base_color_texture].Sample(vertIn.fragUV) * float4(vertIn.fragColor, 1.0) * mat.base_color;

    // ambient
    float3 ambient = pc.scene_data.ambient_light.color.rgb * pc.scene_data.ambient_light.brightness;

    // diffuse
    float3 norm = normalize(vertIn.fragNormal);
    float3 lightDir = normalize(pc.scene_data.point_light.pos - vertIn.fragPos);
    float diff = max(dot(norm, lightDir), 0.0);

    // specular
    float3 viewDir = normalize(pc.scene_data.cam_pos - vertIn.fragPos);
    float3 reflectDir = reflect(-lightDir, norm);
    float shininess = 128;
    float spec = pow(max(dot(viewDir, reflectDir), 0.0), shininess);
    float3 specular = 0.1 * spec * pc.scene_data.point_light.color;

    float3 finalLight = (ambient + diff * pc.scene_data.point_light.color) * texColor.rgb + specular;

    return float4(finalLight, texColor.a);
}

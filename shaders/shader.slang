struct Vertex {
    float3 pos;
    float2 uv;
    float3 color;
    float3 normal;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    float4 light_pos;
    float delta_time;
}

struct Material {
    float4 base_color;
    // float metallic;
    // float roughness;
    // float3 emissive;
    uint base_color_texture;
    // uint metallic_texture;
    // uint normal_texture;
    // uint roughness_texture;
    // uint emissive_texture;
};

struct Particle {
    float2 position;
    float2 velocity;
    float4 color;
}

struct PushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Material* material_buffer;
    float4x4* transform_buffer;
    uint material_index;
    uint instance_index;
};
[[vk_push_constant]] PushConstants pc;

struct ComputePushConstants {
    float delta_time;
    Particle* particles_in;
    Particle* particles_out;
}
[[vk_push_constant]] ComputePushConstants compute_pc;

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

// [shader("vertex")] particle version (temp)
// VSOutput vertex_main(VSInput input) {
//     let p = pc.particle_buffer[input.vertex_index];
//     VSOutput output;
//     output.pointSize = 14.0;
//     output.pos = float4(p.position, 0.0, 1.0);
//     output.fragColor = p.color.rgb;
//     return output;
// }

Sampler2D textures[];

[shader("fragment")]
float4 fragment_main(VSOutput vertIn) : SV_TARGET {
    let mat = pc.material_buffer[pc.material_index];
    float4 texColor = textures[mat.base_color_texture].Sample(vertIn.fragUV) * float4(vertIn.fragColor, 1.0) * mat.base_color;

    float3 norm = normalize(vertIn.fragNormal);
    float3 lightDir = normalize(pc.scene_data.light_pos.xyz - vertIn.fragPos);

    float diff = max(dot(norm, lightDir), 0.0);
    float ambient = 0.15;

    float3 finalLight = ambient + diff;

    return float4(texColor.rgb * finalLight, texColor.a);
}

// [shader("fragment")] particle version (temp)
// float4 fragment_main(PSInput input) : SV_TARGET {
//     float2 coord = input.pointCoord - float2(0.5);
//     return float4(input.fragColor, 0.5 - length(coord));
// }

[shader("compute")]
[numthreads(256,1,1)]
void compute_main(uint3 threadId : SV_DispatchThreadID)
{
    uint index = threadId.x;

    Particle p = compute_pc.particles_in[index];

    p.position += p.velocity * compute_pc.delta_time;

    if (p.position.x <= -1.0 || p.position.x >= 1.0) {
        p.velocity.x = -p.velocity.x;
    }
    if (p.position.y <= -1.0 || p.position.y >= 1.0) {
        p.velocity.y = -p.velocity.y;
    }

    compute_pc.particles_out[index] = p;
}

struct Vertex {
    float3 pos;
    float3 color;
    float3 normal;
    float2 tex_coord;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    float4 light_pos;
    float delta_time;
}

struct Material {
    float4 base_color;
    float metallic;
    float roughness;
    float3 emissive;
    int base_color_texture_index;
    int metallic_texture_index;
    int normal_texture_index;
    int roughness_texture_index;
    int emissive_texture_index;
};

struct Particle {
    float2 position;
    float2 velocity;
    float4 color;
}

struct PushConstants {
    float4x4 model;
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Material* material_buffer;
    uint material_index;
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
    float2 fragTexCoord;
    float3 fragNormal;
    float3 fragPos;
};

[shader("vertex")]
VSOutput vertex_main(VSInput input) {
    let v = pc.vertex_buffer[input.vertex_index];

    VSOutput output;
    float4 worldPos = mul(pc.model, float4(v.pos, 1.0));
    output.fragPos = worldPos.xyz;

    output.pos = mul(pc.scene_data.proj, mul(pc.scene_data.view, worldPos));

    output.fragNormal = mul((float3x3)pc.model, v.normal);

    output.fragColor = v.color;
    output.fragTexCoord = v.tex_coord;
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
    float4 texColor = textures[mat.base_color_texture_index].Sample(vertIn.fragTexCoord) * float4(vertIn.fragColor, 1.0) * mat.base_color;

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

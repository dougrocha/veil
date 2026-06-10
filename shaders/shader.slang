struct Vertex {
    float3 pos;
    float3 color;
    float2 tex_coord;
    float3 normal;
};


struct UniformBuffer {
    float4x4 model;
    float4x4 view;
    float4x4 proj;
    float4 light_pos;
}
ConstantBuffer<UniformBuffer> ubo;

struct PushConstants {
    float4 data;
    Vertex* vertex_buffer;
};

[[vk_push_constant]] PushConstants pc;

struct VSInput {
    uint vertex_index : SV_VertexID;
};

struct VSOutput
{
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
    float4 worldPos = mul(ubo.model, float4(v.pos, 1.0));
    output.fragPos = worldPos.xyz;

    output.pos = mul(ubo.proj, mul(ubo.view, worldPos));

    output.fragNormal = mul((float3x3)ubo.model, v.normal);

    output.fragColor = v.color;
    output.fragTexCoord = v.tex_coord;
    return output;
}

Sampler2D texture;

[shader("fragment")]
float4 fragment_main(VSOutput vertIn) : SV_TARGET {
    float4 texColor = texture.Sample(vertIn.fragTexCoord) * float4(vertIn.fragColor, 1.0);

    float3 norm = normalize(vertIn.fragNormal);
    float3 lightDir = normalize(ubo.light_pos.xyz - vertIn.fragPos);

    float diff = max(dot(norm, lightDir), 0.0);
    float ambient = 0.15;

    float3 finalLight = ambient + diff;

    return float4(texColor.rgb * finalLight * pc.data.rgb, texColor.a);
}

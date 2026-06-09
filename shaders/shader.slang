struct VSInput {
    float3 inPosition;
    float3 inColor;
    float2 inTexCoord;
    float3 inNormal;
};

struct UniformBuffer {
    float4x4 model;
    float4x4 view;
    float4x4 proj;
    float4 light_pos;
}
ConstantBuffer<UniformBuffer> ubo;

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
    VSOutput output;
    float4 worldPos = mul(ubo.model, float4(input.inPosition, 1.0));
    output.fragPos = worldPos.xyz;

    output.pos = mul(ubo.proj, mul(ubo.view, worldPos));

    output.fragNormal = mul((float3x3)ubo.model, input.inNormal);

    output.fragColor = input.inColor;
    output.fragTexCoord = input.inTexCoord;
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

    return float4(texColor.rgb * finalLight, texColor.a);
}

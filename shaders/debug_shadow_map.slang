[[vk_binding(0, 0)]] SamplerState shadow_sampler;
[[vk_binding(0, 0)]] Texture2D<float> shadow_map;

struct VSOutput {
    float4 pos : SV_Position;
    float2 uv;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    VSOutput output;
    float2 uv = float2((vertex_index << 1) & 2, vertex_index & 2);
    output.uv = uv;
    output.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_TARGET {
    float depth = shadow_map.Sample(shadow_sampler, input.uv).r;
    return float4(depth, depth, depth, 1.0);
}

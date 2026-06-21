static const float2 positions[6] = {
    float2(-1.0, -1.0),
    float2(-0.7, -1.0),
    float2(-0.7, -0.7),
    float2(-1.0, -1.0),
    float2(-0.7, -0.7),
    float2(-1.0, -0.7),
};

struct VSOutput {
    float4 pos : SV_Position;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    VSOutput output;
    output.pos = float4(positions[vertex_index], 0.0, 1.0);
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput vertIn) : SV_TARGET {
    return float4(1.0, 0.0, 0.0, 1.0);
}

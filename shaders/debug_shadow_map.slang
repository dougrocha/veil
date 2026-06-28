[[vk_binding(0, 0)]] SamplerCubeArray shadow_cubes;

struct PushConstants {
    float near_plane;
    float far_plane;
    uint face_index;
    uint light_index;
};
[[vk_push_constant]] PushConstants pc;

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

float linearize_depth(float depth, float near, float far) {
    return (2.0 * near * far) / (far + near - depth * (far - near));
}

float3 face_dir(uint face, float2 uv) {
    switch (face) {
        case 0: return normalize(float3( 1.0,  uv.y,  uv.x)); // +X
        case 1: return normalize(float3(-1.0,  uv.y, -uv.x)); // -X
        case 2: return normalize(float3( uv.x,  1.0,  uv.y)); // +Y
        case 3: return normalize(float3( uv.x, -1.0,  uv.y)); // -Y
        case 4: return normalize(float3( uv.x,  uv.y,  1.0)); // +Z
        default: return normalize(float3(-uv.x,  uv.y, -1.0)); // -Z
    }
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_TARGET {
    float2 uv = input.uv * 2.0 - 1.0;
    float3 dir = face_dir(pc.face_index, uv);
    float depth = shadow_cubes.Sample(float4(dir, float(pc.light_index))).r;
    return float4(depth, depth, depth, 1.0);
}

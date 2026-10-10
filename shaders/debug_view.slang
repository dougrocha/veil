#include "bindless.slang"
[[vk_binding(4, 0)]] SamplerCubeArray shadow_cubes;
[[vk_binding(5, 0)]] Sampler2DArray shadow_2d_maps;

[[vk_push_constant]] DebugViewPushConstants pc;

struct VSOutput {
    float4 pos : SV_Position;
    float2 uv;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    VSOutput output;
    float2 uv = float2((vertex_index << 1) & 2, vertex_index & 2);
    output.uv = uv;
    float2 ndc = uv * 2.0 - 1.0;
    output.pos = float4(ndc, 0.0, 1.0);
    return output;
}

float3 face_dir(uint face, float2 uv) {
    uv.y = -uv.y;
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
    if (pc.mode == DEBUG_VIEW_MODE_SHADOW_CUBE_FACE) {
        float2 uv = input.uv * 2.0 - 1.0;
        float3 dir = face_dir(pc.face, uv);
        float depth = shadow_cubes.Sample(float4(dir, float(pc.index))).r;
        return float4(depth, depth, depth, 1.0);
    }

    if (pc.mode == DEBUG_VIEW_MODE_SHADOW_2D) {
        float depth = shadow_2d_maps.Sample(float3(input.uv, float(pc.index))).r;
        return float4(depth, depth, depth, 1.0);
    }

    if (pc.mode == DEBUG_VIEW_MODE_CLUSTER_HEATMAP) {
        SceneData* scene = (SceneData*)pc.scene_data;
        ClusterHeader* headers = (ClusterHeader*)scene->cluster_headers;
        uint2 tile = min(uint2(input.uv * float2(CLUSTER_X, CLUSTER_Y)), uint2(CLUSTER_X - 1, CLUSTER_Y - 1));
        uint count = 0;
        for (uint z = 0; z < CLUSTER_Z; ++z) {
            uint cluster = tile.x + tile.y * CLUSTER_X + z * CLUSTER_X * CLUSTER_Y;
            count = max(count, headers[cluster].light_count);
        }
        float t = saturate(float(count) / 24.0);
        return float4(t, 1.0 - abs(t * 2.0 - 1.0), 1.0 - t, 0.72);
    }

    return gpu_texture(pc.index).Sample(gpu_sampler(SAMPLER_LINEAR_REPEAT), input.uv);
}

import types;

struct SectorVertex {
    float3 pos;
    float4 color;
};

struct PushConstants {
    SceneData* scene_data;
    SectorVertex* vertex_buffer;
    float2 screen_size;
    float thickness;
};
[[vk_push_constant]] PushConstants pc;

struct VSOutput {
    float4 pos : SV_Position;
    float4 color;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    let vertex = pc.vertex_buffer[vertex_index];
    VSOutput output;
    output.pos = mul(pc.scene_data.proj, mul(pc.scene_data.view, float4(vertex.pos, 1.0)));
    output.color = vertex.color;
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_Target {
    return input.color;
}

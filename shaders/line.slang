import types;

struct LineVertex {
    float3 pos;
    float4 color;
};

struct PushConstants {
    SceneData* scene_data;
    LineVertex* vertex_buffer;
};
[[vk_push_constant]] PushConstants pc;

struct VSOutput {
    float4 pos : SV_Position;
    float4 color;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    let v = pc.vertex_buffer[vertex_index];

    VSOutput output;
    output.pos = mul(pc.scene_data.proj, mul(pc.scene_data.view, float4(v.pos, 1.0)));
    output.color = v.color;
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_Target {
    return input.color;
}

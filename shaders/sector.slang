import types;

[[vk_push_constant]] LinePushConstants pc;

struct VSOutput {
    float4 pos : SV_Position;
    float4 color;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    let vertex = pc.vertex_buffer[vertex_index];
    VSOutput output;
    output.pos = mul(pc.scene_data.proj, mul(pc.scene_data.view, float4(vertex.position.xyz, 1.0)));
    output.color = vertex.color;
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_Target {
    return input.color;
}

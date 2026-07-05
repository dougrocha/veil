import types;

struct ShadowPushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Transform* transform_buffer;
    uint instance_index;
    uint light_index;
};
[[vk_push_constant]] ShadowPushConstants pc;

struct VSOutput {
    float4 pos : SV_Position;
    float3 world_pos;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    let v = pc.vertex_buffer[vertex_index];
    let transform = pc.transform_buffer[pc.instance_index];

    float4 world_pos = mul(transform.model, float4(v.pos, 1.0));

    VSOutput output;
    output.pos = mul(pc.scene_data.dir_light_view_proj[pc.light_index], world_pos);
    output.world_pos = world_pos.xyz;
    return output;
}

[shader("fragment")]
void fragment_main(VSOutput input) {
}

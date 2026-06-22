import types;

struct ShadowPushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Transform* transform_buffer;
    uint instance_index;
};
[[vk_push_constant]] ShadowPushConstants pc;

[shader("vertex")]
float4 vertex_main(uint vertex_index : SV_VertexID) : SV_Position {
    let v = pc.vertex_buffer[vertex_index];
    let transform = pc.transform_buffer[pc.instance_index];

    float4 world_pos = mul(transform.model, float4(v.pos, 1.0));

    float4 clip = mul(pc.scene_data.light_space_matrix, world_pos);
    return clip;
}

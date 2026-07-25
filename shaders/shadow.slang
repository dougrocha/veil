import types;

struct ShadowPushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Transform* transform_buffer;
    float4x4 view_proj;
    uint instance_index;
    uint light_type; // 0 = directional, 1 = spot, 2 = point
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
    output.pos = mul(pc.view_proj, world_pos);
    output.world_pos = world_pos.xyz;
    return output;
}

[shader("fragment")]
float fragment_main(VSOutput input) : SV_Depth {
    if (pc.light_type == 0) { // directional
        return input.pos.z;
    }

    float3 light_pos = pc.light_type == 1 ? pc.scene_data.spot_lights[pc.light_index].pos : pc.scene_data.point_lights[pc.light_index].pos;
    float range = pc.light_type == 1 ? pc.scene_data.spot_lights[pc.light_index].range : pc.scene_data.point_lights[pc.light_index].range;
    return length(input.world_pos - light_pos) / range;
}

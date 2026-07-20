import types;

struct ShadowPushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Transform* transform_buffer;
    uint light_type; // 0 = directional, 1 = spot
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
    uint slot = pc.light_type == 1 ? MAX_DIRECTIONAL_LIGHTS + pc.light_index : pc.light_index;
    output.pos = mul(pc.scene_data.shadow_2d_view_proj[slot], world_pos);
    output.world_pos = world_pos.xyz;
    return output;
}

[shader("fragment")]
float fragment_main(VSOutput input) : SV_Depth {
    if (pc.light_type == 1) { // spot
        float3 light_pos = pc.scene_data.spot_lights[pc.light_index].pos;
        return length(input.world_pos - light_pos) / pc.scene_data.shadow_far;
    }

    return input.pos.z;
}

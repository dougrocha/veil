#include "bindless.slang"
import types;

struct VSOutput {
    float4 pos : SV_Position;
    float3 world_pos;
    float2 uv;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID, uint start_vertex_location : SV_StartVertexLocation, uint instance_id : SV_InstanceID) {
    let v = pc.vertex_buffer[vertex_index + start_vertex_location];
    let transform = pc.transform_buffer[pc.instance_ids[pc.instance_offset + instance_id]];

    float4 world_pos = mul(transform.model, float4(v.pos_uv_x.xyz, 1.0));

    VSOutput output;
    output.pos = mul(pc.view_proj, world_pos);
    output.world_pos = world_pos.xyz;
    output.uv = float2(v.pos_uv_x.w, v.normal_uv_y.w);
    return output;
}

[[vk_push_constant]] ShadowPushConstants pc;

[shader("fragment")]
float fragment_main(VSOutput input) : SV_Depth {
    let mat = pc.material_buffer[pc.material_index];
    if (mat.alpha_mode == ALPHA_MODE_MASK) {
        float alpha = mat.base_color_texture.get().Sample(gpu_sampler(SAMPLER_LINEAR_REPEAT), input.uv).a * mat.base_color.a;
        if (alpha < mat.alpha_cutoff) discard;
    }

    if (pc.light_type == LIGHT_TYPE_DIRECTIONAL) {
        // Depth-clamped (pancaked) casters in front of the near plane arrive with pos.z < 0.
        return saturate(input.pos.z);
    }

    float3 light_pos = pc.light_type == LIGHT_TYPE_SPOT ? pc.scene_data.spot_lights[pc.light_index].position_range.xyz : pc.scene_data.point_lights[pc.light_index].position_range.xyz;
    float range = pc.light_type == LIGHT_TYPE_SPOT ? pc.scene_data.spot_lights[pc.light_index].position_range.w : pc.scene_data.point_lights[pc.light_index].position_range.w;
    return length(input.world_pos - light_pos) / range;
}

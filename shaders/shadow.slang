#include "platform.slang"
import types;

struct ShadowPushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Material* material_buffer;
    Transform* transform_buffer;
    float4x4 view_proj;
    uint instance_index;
    uint light_type; // 0 = directional, 1 = spot, 2 = point
    uint light_index;
    uint material_index;
};
struct VSOutput {
    float4 pos : SV_Position;
    float3 world_pos;
    float2 uv;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    let v = pc.vertex_buffer[vertex_index];
    let transform = pc.transform_buffer[pc.instance_index];

    float4 world_pos = mul(transform.model, float4(v.pos.xyz, 1.0));

    VSOutput output;
    output.pos = mul(pc.view_proj, world_pos);
    output.world_pos = world_pos.xyz;
    output.uv = v.uv;
    return output;
}

[[vk_push_constant]] ShadowPushConstants pc;

// Slang lowers a bare `: SV_Depth` return to [[color(0)]] on the Metal target,
// so the value silently went to a nonexistent color attachment and the atlas
// kept the rasterizer's interpolated z instead. Returning it inside a struct
// lowers to [[depth(any)]] on Metal and is equally valid for SPIR-V.
struct PSOutput {
    float depth : SV_Depth;
};

[shader("fragment")]
PSOutput fragment_main(VSOutput input) {
    let mat = pc.material_buffer[pc.material_index];
    if (mat.alpha_mode == 1) {
        float alpha = gpu_texture(mat.base_color_texture).Sample(gpu_sampler(SAMPLER_LINEAR_REPEAT), input.uv).a * mat.base_color.a;
        if (alpha < mat.alpha_cutoff) discard;
    }

    if (pc.light_type == 0) { // directional
        // Depth-clamped (pancaked) casters in front of the near plane arrive with pos.z < 0.
        // Vulkan clamps shader-written depth too; saturate so Metal doesn't depend on it.
        return PSOutput(saturate(input.pos.z));
    }

    float3 light_pos = pc.light_type == 1 ? pc.scene_data.spot_lights[pc.light_index].position_range.xyz : pc.scene_data.point_lights[pc.light_index].position_range.xyz;
    float range = pc.light_type == 1 ? pc.scene_data.spot_lights[pc.light_index].position_range.w : pc.scene_data.point_lights[pc.light_index].position_range.w;
    return PSOutput(length(input.world_pos - light_pos) / range);
}

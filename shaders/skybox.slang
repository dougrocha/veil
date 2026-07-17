import types;

struct SkyboxPushConstants {
    SceneData* scene_data;
};
[[vk_push_constant]] SkyboxPushConstants pc;

[[vk_binding(2, 0)]] SamplerCube skybox;

struct VSOutput {
    float4 pos : SV_Position;
    float3 tex_coords;
};

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    float2 uv = float2((vertex_index << 1) & 2, vertex_index & 2);
    float4 clip_pos = float4(uv * 2.0 - 1.0, 1.0, 1.0);

    float4x4 proj = pc.scene_data.proj;
    float4x4 view = pc.scene_data.view;

    // Unproject clip -> view space direction (camera looks down -Z in view space)
    float3 view_dir = float3(clip_pos.x / proj[0][0], clip_pos.y / proj[1][1], -1.0);

    // Rotate view-space direction to world space (transpose of rotation = inverse)
    float3x3 view_rot = float3x3(view[0].xyz, view[1].xyz, view[2].xyz);
    float3 world_dir = mul(transpose(view_rot), view_dir);

    VSOutput output;
    output.pos = clip_pos;
    output.tex_coords = world_dir;
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_Target {
    return skybox.Sample(input.tex_coords);
}

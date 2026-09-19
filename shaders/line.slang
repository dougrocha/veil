import types;

struct LineVertex {
    float4 pos; // xyz
    float4 color;
};

struct PushConstants {
    SceneData* scene_data;
    LineVertex* vertex_buffer;
    float2 screen_size;
    float thickness;
};
[[vk_push_constant]] PushConstants pc;

struct VSOutput {
    float4 pos : SV_Position;
    float4 color;
};

// two triangles covering the segment quad, sharing the (P0,-) -> (P1,+) diagonal
static const uint corner_endpoint[6] = { 0, 0, 1, 0, 1, 1 };
static const float corner_side[6] = { -1.0, 1.0, 1.0, -1.0, 1.0, -1.0 };

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    let segment = vertex_index / 6;
    let corner = vertex_index % 6;

    let v0 = pc.vertex_buffer[segment * 2 + 0];
    let v1 = pc.vertex_buffer[segment * 2 + 1];

    float4 clip0 = mul(pc.scene_data.proj, mul(pc.scene_data.view, float4(v0.pos.xyz, 1.0)));
    float4 clip1 = mul(pc.scene_data.proj, mul(pc.scene_data.view, float4(v1.pos.xyz, 1.0)));
    float4 color0 = v0.color;
    float4 color1 = v1.color;

    // Vulkan's near clip plane is z = 0. Clip before dividing by w.
    VSOutput output;
    output.pos = float4(0.0, 0.0, -1.0, 1.0);
    output.color = float4(0.0);
    if (clip0.z < 0.0 && clip1.z < 0.0) return output;
    if (clip0.z < 0.0) {
        float t = clip0.z / (clip0.z - clip1.z);
        color0 = lerp(color0, color1, t);
        clip0 = lerp(clip0, clip1, t);
    } else if (clip1.z < 0.0) {
        float t = clip1.z / (clip1.z - clip0.z);
        color1 = lerp(color1, color0, t);
        clip1 = lerp(clip1, clip0, t);
    }

    float2 ndc0 = clip0.xy / clip0.w;
    float2 ndc1 = clip1.xy / clip1.w;

    // direction in pixel space, not NDC, so non-square windows don't skew the perpendicular
    float2 delta_px = (ndc1 - ndc0) * pc.screen_size;
    float length_sq = dot(delta_px, delta_px);
    if (length_sq <= 1e-6) return output;
    float2 dir = delta_px * rsqrt(length_sq);
    float2 perp = float2(-dir.y, dir.x);

    let endpoint = corner_endpoint[corner];
    float4 clip = endpoint == 0 ? clip0 : clip1;
    float2 ndc = endpoint == 0 ? ndc0 : ndc1;

    // pixels -> NDC units, then undo our /w since the hardware divides again
    float2 offset_ndc = perp * corner_side[corner] * (pc.thickness * 0.5) * (2.0 / pc.screen_size);

    output.pos = float4((ndc + offset_ndc) * clip.w, clip.z, clip.w);
    output.color = endpoint == 0 ? color0 : color1;
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_Target {
    return input.color;
}

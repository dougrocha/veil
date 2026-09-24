#include "platform.slang"

struct UIVertex {
    float2 position; // screen-space pixels, top-left origin, y-down
    float2 uv;
    uint color; // packed RGBA8, matches Odin's [4]u8 layout
    uint _pad0;
};

struct PushConstants {
    UIVertex* vertex_buffer;
    float2 screen_size;
    uint atlas_texture;
};
[[vk_push_constant]] PushConstants pc;

struct VSOutput {
    float4 pos : SV_Position;
    float2 uv;
    float4 color;
};

float4 unpack_color(uint c) {
    return float4(
        float((c >> 0) & 0xFF),
        float((c >> 8) & 0xFF),
        float((c >> 16) & 0xFF),
        float((c >> 24) & 0xFF)
    ) / 255.0;
}

[shader("vertex")]
VSOutput vertex_main(uint vertex_index : SV_VertexID) {
    let v = pc.vertex_buffer[vertex_index];

    // Screen space here is y-down. Vulkan's NDC matches that directly; Metal's
    // NDC is y-up, so it needs the flip.
    float2 ndc = (v.position / pc.screen_size) * 2.0 - 1.0;
#if VEIL_METAL
    ndc.y = -ndc.y;
#endif

    VSOutput output;
    output.pos = float4(ndc, 0.0, 1.0);
    output.uv = v.uv;
    output.color = unpack_color(v.color);
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_TARGET {
    float coverage = gpu_texture(pc.atlas_texture).Sample(gpu_sampler(SAMPLER_LINEAR_REPEAT), input.uv).r;
    return float4(input.color.rgb, input.color.a * coverage);
}

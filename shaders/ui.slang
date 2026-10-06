#include "bindless.slang"

[[vk_push_constant]] UIPushConstants pc;

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

    // Screen space is y-down, which matches Vulkan NDC directly.
    float2 ndc = (v.position / pc.screen_size) * 2.0 - 1.0;

    VSOutput output;
    output.pos = float4(ndc, 0.0, 1.0);
    output.uv = v.uv;
    output.color = unpack_color(v.color);
    return output;
}

[shader("fragment")]
float4 fragment_main(VSOutput input) : SV_TARGET {
    float coverage = pc.atlas_texture.get().Sample(gpu_sampler(SAMPLER_LINEAR_CLAMP), input.uv).r;
    return float4(input.color.rgb, input.color.a * coverage);
}

#include "bindless.slang"
#include "storage.slang"
#include "bloom_common.slang"

// Reads the smaller mip around uv and returns the blurred color to add into the destination.
// 3x3 tent filter (1-2-1 weights over 16), offsets scaled by texel * radius.
float3 upsample(Texture2D<float4> src, SamplerState s, float2 uv, float2 texel, float radius) {
    float2 d = texel * radius;

    float3 c = src.SampleLevel(s, uv, 0).rgb * 4.0;

    c += src.SampleLevel(s, uv + float2(-d.x, 0), 0).rgb * 2.0;
    c += src.SampleLevel(s, uv + float2( d.x, 0), 0).rgb * 2.0;
    c += src.SampleLevel(s, uv + float2(0, -d.y), 0).rgb * 2.0;
    c += src.SampleLevel(s, uv + float2(0,  d.y), 0).rgb * 2.0;

    c += src.SampleLevel(s, uv + float2(-d.x, -d.y), 0).rgb;
    c += src.SampleLevel(s, uv + float2( d.x, -d.y), 0).rgb;
    c += src.SampleLevel(s, uv + float2(-d.x,  d.y), 0).rgb;
    c += src.SampleLevel(s, uv + float2( d.x,  d.y), 0).rgb;

    return c / 16.0;
}

[shader("compute")]
[numthreads(POST_GROUP_SIZE, POST_GROUP_SIZE, 1)]
void compute_main(uint3 id : SV_DispatchThreadID) {
    RWTexture2D<float4> dst = pc.dst_storage.get();
    uint width, height;
    dst.GetDimensions(width, height);
    if (id.x >= width || id.y >= height) return;

    float2 uv = (float2(id.xy) + 0.5) / float2(width, height);
    float3 blurred = upsample(pc.src_texture.get(), gpu_sampler(SAMPLER_LINEAR_CLAMP), uv, pc.src_texel_size, pc.radius);
    // dst still holds its own downsampled level; adding keeps that radius and stacks the wider one.
    dst[id.xy] = float4(dst[id.xy].rgb + blurred, 1.0);
}

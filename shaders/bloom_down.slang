#include "bindless.slang"
#include "storage.slang"
#include "bloom_common.slang"

float luma(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// Reads src around uv and returns the downsampled color for one destination texel.
// CoD:AW 13-tap downsample: five overlapping 2x2 boxes, Karis-weighted when pc.karis != 0.
float3 downsample(Texture2D<float4> src, SamplerState s, float2 uv, float2 texel) {
    // Outer 3x3 grid, 2 texels apart.
    float3 a = src.SampleLevel(s, uv + float2(-2, -2) * texel, 0).rgb;
    float3 b = src.SampleLevel(s, uv + float2( 0, -2) * texel, 0).rgb;
    float3 c = src.SampleLevel(s, uv + float2( 2, -2) * texel, 0).rgb;
    float3 d = src.SampleLevel(s, uv + float2(-2,  0) * texel, 0).rgb;
    float3 e = src.SampleLevel(s, uv,                         0).rgb;
    float3 f = src.SampleLevel(s, uv + float2( 2,  0) * texel, 0).rgb;
    float3 g = src.SampleLevel(s, uv + float2(-2,  2) * texel, 0).rgb;
    float3 h = src.SampleLevel(s, uv + float2( 0,  2) * texel, 0).rgb;
    float3 i = src.SampleLevel(s, uv + float2( 2,  2) * texel, 0).rgb;
    // Inner 2x2, 1 texel from the center.
    float3 j = src.SampleLevel(s, uv + float2(-1, -1) * texel, 0).rgb;
    float3 k = src.SampleLevel(s, uv + float2( 1, -1) * texel, 0).rgb;
    float3 l = src.SampleLevel(s, uv + float2(-1,  1) * texel, 0).rgb;
    float3 m = src.SampleLevel(s, uv + float2( 1,  1) * texel, 0).rgb;

    // Five overlapping boxes, each the average of its 4 taps.
    float3 center = (j + k + l + m) * 0.25;
    float3 tl     = (a + b + d + e) * 0.25;
    float3 tr     = (b + c + e + f) * 0.25;
    float3 bl     = (d + e + g + h) * 0.25;
    float3 br     = (e + f + h + i) * 0.25;

    if (pc.karis == 0) {
        return center * 0.5 + (tl + tr + bl + br) * 0.125;
    }

    // Karis average: weight each box by 1 / (1 + luma) so a single very bright texel can't dominate.
    float w_center = 1.0 / (1.0 + luma(center));
    float w_tl = 1.0 / (1.0 + luma(tl));
    float w_tr = 1.0 / (1.0 + luma(tr));
    float w_bl = 1.0 / (1.0 + luma(bl));
    float w_br = 1.0 / (1.0 + luma(br));

    float3 sum = w_center * center + w_tl * tl + w_tr * tr + w_bl * bl + w_br * br;
    float weight_sum = w_center + w_tl + w_tr + w_bl + w_br;
    return sum / weight_sum;
}

[shader("compute")]
[numthreads(POST_GROUP_SIZE, POST_GROUP_SIZE, 1)]
void compute_main(uint3 id : SV_DispatchThreadID) {
    RWTexture2D<float4> dst = pc.dst_storage.get();
    uint width, height;
    dst.GetDimensions(width, height);
    if (id.x >= width || id.y >= height) return;

    float2 uv = (float2(id.xy) + 0.5) / float2(width, height);
    float3 color = downsample(pc.src_texture.get(), gpu_sampler(SAMPLER_LINEAR_CLAMP), uv, pc.src_texel_size);
    dst[id.xy] = float4(color, 1.0);
}

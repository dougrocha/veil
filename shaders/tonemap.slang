#include "bindless.slang"
#include "storage.slang"

struct TonemapPushConstants {
    uint hdr_texture; // bindless sampled index of the HDR image
    uint out_storage; // bindless storage index of the LDR draw image
    float exposure;
    uint bloom_texture; // bindless sampled index of bloom mip 0 (half res)
    float bloom_strength; // pre-normalized: setting / bloom level count
};
[[vk_push_constant]] TonemapPushConstants pc;

float3 ACESFilm(float3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;

    return saturate(
        (x * (a * x + b)) /
        (x * (c * x + d) + e)
    );
}

// HDR scene color in, display-range [0, 1] linear color out (present_blit does the sRGB encode).
float3 tonemap(float3 hdrColor, float exposure) {
    float3 color = hdrColor;

    color *= exposure;
    color = ACESFilm(color);

    return color;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void compute_main(uint3 id : SV_DispatchThreadID) {
    RWTexture2D<float4> out_image = gpu_storage(pc.out_storage);
    uint width, height;
    out_image.GetDimensions(width, height);
    if (id.x >= width || id.y >= height) return;

    float4 hdr = gpu_texture(pc.hdr_texture).Load(int3(id.xy, 0));
    // Bloom is half res, so sample it with UVs and let bilinear filtering upscale it.
    float2 uv = (float2(id.xy) + 0.5) / float2(width, height);
    float3 bloom = gpu_texture(pc.bloom_texture).SampleLevel(gpu_sampler(SAMPLER_LINEAR_CLAMP), uv, 0).rgb;

    // TODO: could use lerp later
    float3 scene = hdr.rgb + bloom * pc.bloom_strength;

    out_image[id.xy] = float4(tonemap(scene, pc.exposure), hdr.a);
}

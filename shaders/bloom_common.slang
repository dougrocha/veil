// Shared by bloom_down.slang and bloom_up.slang. Mirrors BloomPushConstants in types.odin.
struct BloomPushConstants {
    uint src_texture;    // bindless sampled index of the mip (or hdr) being read
    uint dst_storage;    // bindless storage index of the mip being written
    float2 src_texel_size; // 1 / source size, for sample offsets
    uint karis;          // downsample only: 1 on the first pass (reading hdr)
    float radius;        // upsample only: tent filter radius, in source texels
};
[[vk_push_constant]] BloomPushConstants pc;

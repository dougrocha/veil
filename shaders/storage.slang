// Bindless storage images for compute post passes (set 1; set 0 is the bindless texture set).
// Kept out of bindless.slang because graphics shaders use set 1 for the global descriptor.
// Slots come from the STORAGE_SLOT_* constants in post.odin.
import types;

[[vk_binding(0, 1)]] [format("rgba16f")] RWTexture2D<float4> storage_images[BINDLESS_STORAGE_IMAGE_COUNT];

RWTexture2D<float4> gpu_storage(uint index) {
    return storage_images[index];
}

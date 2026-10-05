// Bindless storage images for compute post passes: binding 3 of the bindless table. Kept out of
// bindless.slang because only compute shaders may use them (the binding is compute-only).
// Slots come from the STORAGE_SLOT_* constants in post.odin.
import types;

[[vk_binding(3, 0)]] [format("rgba16f")] RWTexture2D<float4> storage_images[BINDLESS_STORAGE_IMAGE_COUNT];

RWTexture2D<float4> gpu_storage(uint index) {
    return storage_images[index];
}

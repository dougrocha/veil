// BINDLESS_TEXTURE_COUNT is injected by shader_system_create at
// runtime. These fallbacks only exist so slangd / a bare slangc invocation can
// still parse the shaders; the engine always overrides them.
#ifndef BINDLESS_TEXTURE_COUNT
#define BINDLESS_TEXTURE_COUNT 1024
#endif

// Bindless resource access. Shaders go through gpu_texture / gpu_sampler
// instead of touching the binding directly, so how an index resolves to a
// descriptor (e.g. NonUniformResourceIndex, descriptor heap) can change here.
// Texture indices come from the texture system; sampler indices are the fixed
// SAMPLER_* constants from gpu_types.odin.
import types;

struct BindlessTextures {
    Texture2D<float4> textures[BINDLESS_TEXTURE_COUNT];
    SamplerState samplers[BINDLESS_SAMPLER_COUNT];
}
[[vk_binding(0, 0)]] ParameterBlock<BindlessTextures> bindless;

Texture2D<float4> gpu_texture(uint index) {
    return bindless.textures[index];
}

SamplerState gpu_sampler(uint index) {
    return bindless.samplers[index];
}

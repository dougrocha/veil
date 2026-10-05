// BINDLESS_TEXTURE_COUNT is injected by shader_system_create at
// runtime. These fallbacks only exist so slangd / a bare slangc invocation can
// still parse the shaders; the engine always overrides them.
#ifndef BINDLESS_TEXTURE_COUNT
#define BINDLESS_TEXTURE_COUNT 1024
#endif

// The bindless table: set 0 of every pipeline (backend/bindless.odin). Shaders go through
// gpu_texture / gpu_sampler / gpu_cube instead of touching the bindings directly, so how an
// index resolves to a descriptor (e.g. NonUniformResourceIndex, descriptor heap) can change here.
// Texture and cube indices come from the texture system; sampler indices are the fixed
// SAMPLER_* constants from gpu_types.odin.
//
//   binding 0  Texture2D[]             gpu_texture
//   binding 1  SamplerState[]          gpu_sampler
//   binding 2  TextureCube[]           gpu_cube
//   binding 3  RWTexture2D[]           gpu_storage (storage.slang, compute only)
//   binding 4  depth cube array        declared by its users (mesh: comparison, debug_view: plain)
//   binding 5  depth 2D array          declared by its users
import types;

[[vk_binding(0, 0)]] Texture2D<float4> textures[BINDLESS_TEXTURE_COUNT];
[[vk_binding(1, 0)]] SamplerState samplers[BINDLESS_SAMPLER_COUNT];
[[vk_binding(2, 0)]] TextureCube<float4> cubes[BINDLESS_CUBE_COUNT];

Texture2D<float4> gpu_texture(uint index) {
    return textures[index];
}

SamplerState gpu_sampler(uint index) {
    return samplers[index];
}

TextureCube<float4> gpu_cube(uint index) {
    return cubes[index];
}

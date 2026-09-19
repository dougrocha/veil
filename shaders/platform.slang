// BINDLESS_TEXTURE_COUNT and VEIL_METAL are injected by shader_system_create at
// runtime. These fallbacks only exist so slangd / a bare slangc invocation can
// still parse the shaders; the engine always overrides them.
#ifndef BINDLESS_TEXTURE_COUNT
#define BINDLESS_TEXTURE_COUNT 1024
#endif

#ifndef VEIL_METAL
#define VEIL_METAL 0
#endif

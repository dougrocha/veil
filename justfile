# Linux x86_64
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Binaries live in build/, one level below the shared libraries.
build_flags := "-collection:shared=shared -collection:veil=src -custom-attribute:shader_shared -extra-linker-flags:'-rpath $ORIGIN/../shared/odin-slang/slang/lib'"
debug_flags := "-debug -sanitize:address"
release_flags := "-o:speed -define:VEIL_VALIDATION=false"

build: prepare
    odin build src {{build_flags}} -out:build/veil

build-debug: prepare
    odin build src {{build_flags}} {{debug_flags}} -out:build/veil-debug

build-release: prepare
    odin build src {{build_flags}} {{release_flags}} -out:build/veil-release

run: build
    ./build/veil

debug: build-debug
    bash tools/run-debug.sh ./build/veil-debug

release: build-release
    ./build/veil-release

# Format sources, excluding vendored and generated files.
format:
    rg --files src tools -g '*.odin' -g '!*_generated.odin' | xargs -n1 odinfmt -w

[private]
prepare: gpu-types vma slang-glslang
    @mkdir -p build

# Regenerate shaders/types.slang and the layout asserts from the @(shader_shared) declarations.
# Runs every build: the tool only rewrites files whose contents change.
gpu-types: gpu-types-tool
    ./build/gpu_types_gen

# Fails when the generated GPU types are stale.
gpu-types-check: gpu-types-tool
    ./build/gpu_types_gen --check

[private]
gpu-types-tool:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build
    tool=build/gpu_types_gen
    stale=0
    [ -x "$tool" ] || stale=1
    for f in tools/gpu_types_gen/*.odin; do [ "$f" -nt "$tool" ] && stale=1; done
    [ "$stale" = 0 ] || odin build tools/gpu_types_gen -out:"$tool"

# Fetch spirv-opt once, matching the vendored Slang release.
slang-glslang:
    #!/usr/bin/env bash
    set -euo pipefail
    lib_dir=shared/odin-slang/slang/lib
    [ -f "$lib_dir/libslang-glslang.so" ] && exit 0
    url=https://github.com/shader-slang/slang/releases/download/v2025.16.1/slang-2025.16.1-linux-x86_64.tar.gz
    curl -fsSL "$url" | tar xz -C "$lib_dir" --strip-components=1 lib/libslang-glslang.so

# Build VulkanMemoryAllocator once.
vma:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f shared/odin-vma/libvma_linux_x86_64.a ] && exit 0
    cd shared/odin-vma
    premake5 --vk-version=4 gmake
    cd build/make/linux
    make config=release_x86_64 CXXFLAGS="-Wno-unused-parameter -Wno-missing-field-initializers -Wno-unused-variable"

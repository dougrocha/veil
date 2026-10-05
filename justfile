out_base := "build/veil"
# binaries live in build/, so the rpath climbs one level back to the repo root
slang_rpath := if os() == "macos" { "@executable_path/../shared/odin-slang/slang/lib" } else { "$ORIGIN/../shared/odin-slang/slang/lib" }

# build src -> build/veil
build: gpu-types vma slang-glslang
    @mkdir -p build
    odin build src -collection:shared=shared -out:{{out_base}} \
        -extra-linker-flags:'-rpath {{slang_rpath}}'

# build with debug info and address sanitizer -> build/veil-debug
build-debug: gpu-types vma slang-glslang
    @mkdir -p build
    odin build src -collection:shared=shared -out:{{out_base}}-debug \
        -extra-linker-flags:'-rpath {{slang_rpath}}' \
        -debug -sanitize:address

# optimized, no validation layers -> build/veil-release
build-release: gpu-types vma slang-glslang
    @mkdir -p build
    odin build src -collection:shared=shared -out:{{out_base}}-release \
        -extra-linker-flags:'-rpath {{slang_rpath}}' \
        -o:speed -define:VEIL_VALIDATION=false

# build, then run
run: build
    ./{{out_base}}

# release build, then run
release: build-release
    ./{{out_base}}-release

# debug build, then run
debug: build-debug
    ./{{out_base}}-debug

# format odin sources (skips shared/ and generated files)
format:
    #!/usr/bin/env bash
    git ls-files 'src/*.odin' 'tools/*.odin' | grep -v '_generated\.odin$' | xargs -n1 odinfmt -w

# regenerate shaders/types.slang only when its inputs are newer than it
gpu-types:
    #!/usr/bin/env bash
    set -euo pipefail
    out=shaders/types.slang
    inputs=(src/graphics/gpu_types.odin tools/generate-gpu-types.sh tools/gpu_types_gen/*.odin)
    if [ -f "$out" ]; then
        stale=0
        for f in "${inputs[@]}"; do [ "$f" -nt "$out" ] && stale=1; done
        [ "$stale" = 0 ] && exit 0
    fi
    ./tools/generate-gpu-types.sh

# fetch libslang-glslang (spirv-opt) once; the odin-slang submodule only vendors libslang
slang-glslang:
    #!/usr/bin/env bash
    set -euo pipefail
    version=2025.16.1
    case "$(uname -s)" in Darwin) os=macos; ext=dylib ;; *) os=linux; ext=so ;; esac
    case "$(uname -m)" in arm64|aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
    lib_dir=shared/odin-slang/slang/lib
    [ -f "$lib_dir/libslang-glslang.$ext" ] && exit 0
    url="https://github.com/shader-slang/slang/releases/download/v$version/slang-$version-$os-$arch.tar.gz"
    echo "fetching libslang-glslang.$ext from $url"
    curl -fsSL "$url" | tar xz -C "$lib_dir" --strip-components=1 "lib/libslang-glslang.$ext"
    # untracked in the submodule; hide it from the parent status (local config only)
    git config diff.ignoreSubmodules untracked

# build VulkanMemoryAllocator once
[linux]
vma:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f shared/odin-vma/libvma_linux_x86_64.a ] && exit 0
    cd shared/odin-vma
    premake5 --vk-version=4 gmake
    cd build/make/linux
    make config=release_x86_64 CXXFLAGS="-Wno-unused-parameter -Wno-missing-field-initializers -Wno-unused-variable"

[macos]
vma:

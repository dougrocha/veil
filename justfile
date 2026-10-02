out_base := "odin-vulkan"
slang_rpath := if os() == "macos" { "@executable_path/shared/odin-slang/slang/lib" } else { "$ORIGIN/shared/odin-slang/slang/lib" }

# build src -> odin-vulkan.out
build: gpu-types vma slang-glslang
    odin build src -collection:shared=shared -out:{{out_base}}.out \
        -extra-linker-flags:'-rpath {{slang_rpath}}'

# build with debug info and address sanitizer -> odin-vulkan-debug.out
debug: gpu-types vma slang-glslang
    odin build src -collection:shared=shared -out:{{out_base}}-debug.out \
        -extra-linker-flags:'-rpath {{slang_rpath}}' \
        -debug -sanitize:address

# optimized, no validation layers -> odin-vulkan-release.out
build-release: gpu-types vma slang-glslang
    odin build src -collection:shared=shared -out:{{out_base}}-release.out \
        -extra-linker-flags:'-rpath {{slang_rpath}}' \
        -o:speed -define:VEIL_VALIDATION=false

# build, then run
run: build
    ./{{out_base}}.out

# release build, then run
release: build-release
    ./{{out_base}}-release.out

# debug build, then run
run-debug: debug
    ./{{out_base}}-debug.out

# format odin sources (skips shared/ and generated files)
format:
    #!/usr/bin/env bash
    git ls-files 'src/*.odin' 'tools/*.odin' | grep -v '_generated\.odin$' | xargs -n1 odinfmt -w

gpu-types:
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

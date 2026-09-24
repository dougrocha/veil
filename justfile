out_base := if os() == "macos" { "odin-metal" } else { "odin-vulkan" }
slang_rpath := if os() == "macos" { "@executable_path/shared/odin-slang/slang/lib" } else { "$ORIGIN/shared/odin-slang/slang/lib" }

# build src -> odin-vulkan.out (odin-metal.out on macos)
build: gpu-types vma
    odin build src -collection:shared=shared -out:{{out_base}}.out \
        -extra-linker-flags:'-rpath {{slang_rpath}}'

# build with debug info and address sanitizer -> odin-vulkan-debug.out
debug: gpu-types vma
    odin build src -collection:shared=shared -out:{{out_base}}-debug.out \
        -extra-linker-flags:'-rpath {{slang_rpath}}' \
        -debug -sanitize:address

# build, then run
run: build
    ./{{out_base}}.out

# debug build, then run
run-debug: debug
    ./{{out_base}}-debug.out

# format odin sources (skips shared/ and generated files)
format:
    #!/usr/bin/env bash
    git ls-files 'src/*.odin' 'tools/*.odin' | grep -v '_generated\.odin$' | xargs -n1 odinfmt -w

gpu-types:
    ./tools/generate-gpu-types.sh

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

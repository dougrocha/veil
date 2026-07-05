#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(uname)" = "Darwin" ]; then
    SLANG_RPATH="@executable_path/shared/odin-slang/slang/lib"
else
    SLANG_RPATH="\$ORIGIN/shared/odin-slang/slang/lib"

    if [ ! -f "$SCRIPT_DIR/shared/odin-vma/libvma_linux_x86_64.a" ]; then
        cd "$SCRIPT_DIR/shared/odin-vma"
        premake5 --vk-version=4 gmake
        cd build/make/linux
        make config=release_x86_64 CXXFLAGS="-Wno-unused-parameter -Wno-missing-field-initializers -Wno-unused-variable"
        cd "$SCRIPT_DIR"
    fi
fi

odin build src -collection:shared=shared -out:odin-vulkan.out \
    -extra-linker-flags:"-rpath '$SLANG_RPATH'"

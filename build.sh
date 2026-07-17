#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILD_FLAGS=()
OUT_NAME="odin-vulkan.out"
if [ "$1" = "debug" ]; then
    BUILD_FLAGS+=(-debug -sanitize:address)
    OUT_NAME="odin-vulkan-debug.out"
fi

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

odin build src -collection:shared=shared -out:"$OUT_NAME" \
    -extra-linker-flags:"-rpath '$SLANG_RPATH'" \
    "${BUILD_FLAGS[@]}"

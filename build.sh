#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/tools/generate-gpu-types.sh"

BUILD_FLAGS=()
OUT_BASE="odin-vulkan"
if [ "$1" = "debug" ]; then
    BUILD_FLAGS+=(-debug -sanitize:address)
fi

if [ "$(uname)" = "Darwin" ]; then
    OUT_BASE="odin-metal"
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

OUT_NAME="$OUT_BASE.out"
if [ "$1" = "debug" ]; then
    OUT_NAME="$OUT_BASE-debug.out"
fi

odin build src -collection:shared=shared -out:"$OUT_NAME" \
    -extra-linker-flags:"-rpath $SLANG_RPATH" \
    "${BUILD_FLAGS[@]}"

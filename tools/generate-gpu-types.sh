#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

slang_output="$(mktemp)"
assert_output="$(mktemp)"
trap 'rm -f "$slang_output" "$assert_output"' EXIT

odin run tools/gpu_types_gen \
    -collection:shared=shared \
    -collection:veil=src \
    -define:GPU_TYPES_GENERATING=true > "$slang_output"

slang_target="shaders/types.slang"
assert_target="src/graphics/layout_asserts_generated.odin"

if [[ "${1:-}" == "--check" ]]; then
    cmp --silent "$slang_output" "$slang_target" || {
        diff -u "$slang_target" "$slang_output" || true
        echo "GPU shader types are stale; run ./tools/generate-gpu-types.sh" >&2
        exit 1
    }
else
    cp "$slang_output" "$slang_target"
fi

odin run tools/layout_gen \
    -collection:shared=shared \
    -extra-linker-flags:"-rpath $repo_dir/shared/odin-slang/slang/lib" > "$assert_output"

if [[ "${1:-}" == "--check" ]]; then
    cmp --silent "$assert_output" "$assert_target" || {
        diff -u "$assert_target" "$assert_output" || true
        echo "GPU layout assertions are stale; run ./tools/generate-gpu-types.sh" >&2
        exit 1
    }
else
    cp "$assert_output" "$assert_target"
fi

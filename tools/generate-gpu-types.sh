#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

slang_output="$(mktemp)"
trap 'rm -f "$slang_output"' EXIT

odin run tools/gpu_types_gen \
    -collection:shared=shared \
    -collection:veil=src > "$slang_output"

slang_target="shaders/types.slang"

if [[ "${1:-}" == "--check" ]]; then
    cmp --silent "$slang_output" "$slang_target" || {
        diff -u "$slang_target" "$slang_output" || true
        echo "GPU shader types are stale; run ./tools/generate-gpu-types.sh" >&2
        exit 1
    }
else
    cp "$slang_output" "$slang_target"
fi

#!/usr/bin/env bash
set -e

PATHS=(
    "$(odin root)/core"
    "$(odin root)/vendor"
    "src"
    "shared"
)

odin-tags --output-path tags "${PATHS[@]}"

#!/usr/bin/env bash
set -euo pipefail

# Keep NVIDIA libraries loaded so LeakSanitizer can match lsan.supp at exit.
shopt -s nullglob
nvidia_libs=(/usr/lib/libnvidia-glcore.so.* /usr/lib/libnvidia-glsi.so.*)
preload=$(IFS=:; echo "${nvidia_libs[*]}")
export LD_PRELOAD="${preload}${LD_PRELOAD:+:${LD_PRELOAD}}"
export LSAN_OPTIONS="${LSAN_OPTIONS:+${LSAN_OPTIONS}:}suppressions=lsan.supp:print_suppressions=0"
exec "$@"

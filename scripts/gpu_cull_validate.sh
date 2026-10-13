#!/usr/bin/env bash
# usage: scripts/gpu_cull_validate.sh <out_dir> [frames]
# Dumps the batch-boundary and 32k single-run scenes with GPU culling off (CPU path) and on, then
# compares frame by frame. The GPU-on run also checks its ids against the CPU list (VEIL_GPU_CULL_VALIDATE).
# Needs the veil-tools helpers; override with DUMP=/ COMPARE=.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: gpu_cull_validate.sh <out_dir> [frames]}
frames=${2:-3}
dump=${DUMP:-/home/doug/dev/veil-tools/dump.sh}
compare=${COMPARE:-/home/doug/dev/veil-tools/compare.sh}
for scene in load_cull_batch_boundary load_cull_32k_single_run; do
  name=${scene#load_}
  for gpu in 0 1; do
    VEIL_GPU_CULL=$gpu VEIL_GPU_CULL_VALIDATE=$gpu "$dump" "$here" "$scene" "$out/${name}_gpu$gpu" "$frames"
  done
  # The GPU-on run must have validated at least one frame, and no frame may report a mismatch or false negative.
  log="$out/${name}_gpu1.log"
  rg -q 'GPU culling validation: batches=' "$log" || { echo "$name: no GPU culling validation lines in $log" >&2; exit 1; }
  if rg -q 'mismatches=[1-9]|false_negatives=[1-9]' "$log"; then
    echo "$name: GPU culling validation reported mismatches, see $log" >&2
    exit 1
  fi
  for ((i = 0; i < frames; i++)); do
    f=$(printf "%03d" "$i")
    result=$("$compare" "$out/${name}_gpu0_$f.png" "$out/${name}_gpu1_$f.png" "$out/${name}_diff_$f.png") || {
      echo "$name frame $i: compare failed" >&2
      exit 1
    }
    echo "$name frame $i: $result"
    if [[ ! $result =~ differing_pixels\(fuzz1%\)=0[[:space:]] ]]; then
      echo "$name frame $i: GPU-on frame differs from GPU-off frame" >&2
      exit 1
    fi
  done
done

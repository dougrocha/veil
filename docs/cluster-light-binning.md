# Cluster light binning interface

The compute pass in `shaders/clusters.slang` writes a compact list of point and spot light indices
for a 16x9x24 froxel grid. Part 3 can read the addresses from `SceneData.cluster_headers` and
`SceneData.cluster_indices`.

`cluster_headers` points to `CLUSTER_COUNT` `ClusterHeader` records. Each record contains a
`light_offset` and `light_count`, measured in `u32` elements. `cluster_indices` points to a global
index array with `CLUSTER_INDEX_CAPACITY` entries. A point index is in `[0, point_light_count)`;
spot indices start at `MAX_POINT_LIGHTS`. The allocator counter is private to the compute pass.
The current cap is 131,072 indices (512 KiB per frame slot); when allocation exceeds it, counts
are clamped and `VEIL_CLUSTER_VALIDATE=1` reports overflow.

For pixel `(px, py)` in render extent `(W, H)` and positive view depth `d`, lookup is:

```text
x = clamp(floor(px / W * CLUSTER_X), 0, CLUSTER_X - 1)
y = clamp(floor(py / H * CLUSTER_Y), 0, CLUSTER_Y - 1)
z = clamp(floor(log(d / near) / log(far / near) * CLUSTER_Z), 0, CLUSTER_Z - 1)
cluster = x + y * CLUSTER_X + z * CLUSTER_X * CLUSTER_Y
header = cluster_headers[cluster]
for i in 0 .. header.light_count:
    light_index = cluster_indices[header.light_offset + i]
```

Clamp all three coordinates. In particular, `d == far` produces `z == CLUSTER_Z` before clamping,
so it must map to the final slice.

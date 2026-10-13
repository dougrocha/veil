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
if (header.light_count & CLUSTER_OVERFLOW_BIT) != 0:
    // List is incomplete: shade with brute force over every point and spot light.
else:
    count = header.light_count & ~CLUSTER_OVERFLOW_BIT
    for i in 0 .. count:
        light_index = cluster_indices[header.light_offset + i]
        if light_index < MAX_POINT_LIGHTS:
            point light light_index, if light_index < point_light_count
        else:
            spot light light_index - MAX_POINT_LIGHTS, if < spot_light_count
```

Clamp all three coordinates. In particular, `d == far` produces `z == CLUSTER_Z` before clamping,
so it must map to the final slice.

`CLUSTER_OVERFLOW_BIT` is `0x80000000`. Set on a header, it means the stored list was truncated, so
the list must not be used even partially; fall back to brute force for that pixel. Always mask the
bit off before using `light_count` as a loop bound. Also bounds-check each decoded index against
its light count, as `shaders/mesh.slang` does.

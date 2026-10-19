import types;

[[vk_push_constant]] CullPushConstants pc;

// Dispatched three times (pc.init_commands): 1 writes one command per batch, 0 tests the candidates
// (x covers a batch, y is the batch), 2 compacts each batch. The first and last run over x = batch.
[shader("compute")]
[numthreads(256,1,1)]
void compute_main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint index = dispatch_id.x;
    if (pc.init_commands == 1) {
        if (index >= pc.run_count) return;
        CullRun run = pc.runs[index];
        DrawIndexedIndirectCommand command;
        command.index_count = run.index_count;
        command.instance_count = 0;
        command.first_index = run.first_index;
        command.vertex_offset = run.vertex_offset;
        command.first_instance = run.first_output;
        pc.commands[index] = command;
        return;
    }
    if (pc.init_commands == 2) {
        if (index >= pc.run_count) return;
        CullRun run = pc.runs[index];
        uint visible_count = 0;
        // A batch holds at most 1024 candidates (GPU_CULL_BATCH_CANDIDATES). One invocation scans it in O(n),
        // avoiding atomics and preserving candidate order. Flags and ids share the batch's output range;
        // the write index never passes the read index.
        for (uint offset = 0; offset < run.candidate_count; ++offset) {
            if (pc.output_ids[run.first_output + offset] == 0) continue;
            pc.output_ids[run.first_output + visible_count] = pc.candidates[run.first_candidate + offset];
            visible_count++;
        }
        pc.commands[index].instance_count = visible_count;
        return;
    }
    CullRun run = pc.runs[dispatch_id.y];
    if (index >= run.candidate_count) return;

    uint draw_id = pc.candidates[run.first_candidate + index] >> INSTANCE_DRAW_ID_SHIFT;
    float4x4 world = pc.transforms[draw_id].model;
    float4 center4 = mul(world, float4(run.bounds_center.xyz, 1.0));
    float3 extents = run.bounds_extents.xyz;
    float3 world_extents = float3(
        abs(world[0][0]) * extents.x + abs(world[0][1]) * extents.y + abs(world[0][2]) * extents.z,
        abs(world[1][0]) * extents.x + abs(world[1][1]) * extents.y + abs(world[1][2]) * extents.z,
        abs(world[2][0]) * extents.x + abs(world[2][1]) * extents.y + abs(world[2][2]) * extents.z);
    // Through the pointer, so each thread loads only the planes it tests, not the whole view.
    CullView* view = pc.views + run.view_index;
    uint visible = 1;
    for (uint p = 0; p < 6 && visible != 0; ++p) {
        if (view.skip_near != 0 && p == FRUSTUM_NEAR_PLANE) continue;
        float4 plane = view.planes[p];
        float radius = dot(world_extents, abs(plane.xyz));
        if (dot(plane.xyz, center4.xyz) - plane.w < -radius) visible = 0;
    }
    pc.output_ids[run.first_output + index] = visible;
}

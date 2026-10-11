import types;

[[vk_push_constant]] CullPushConstants pc;

[shader("compute")]
[numthreads(256,1,1)]
void compute_main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint index = dispatch_id.x;
    if (pc.init_commands == 1) {
        if (index >= pc.run_count) return;
        CullRun run = pc.runs[index];
        run.instance_count = 0;
        run.first_instance = run.first_candidate;
        pc.runs[index] = run;
        DrawIndexedIndirectCommand command;
        command.index_count = run.index_count;
        command.instance_count = 0;
        command.first_index = run.first_index;
        command.vertex_offset = run.vertex_offset;
        command.first_instance = run.first_candidate;
        pc.commands[index] = command;
        return;
    }
    if (pc.init_commands == 2) {
        if (index >= pc.run_count) return;
        CullRun run = pc.runs[index];
        uint visible_count = 0;
        // A run contains at most 4096 candidates. One invocation scans it in O(n), avoiding
        // atomics and preserving candidate order while keeping the scan simple at engine scale.
        for (uint offset = 0; offset < run.candidate_count; ++offset) {
            uint candidate_index = run.first_candidate + offset;
            if (pc.output_ids[candidate_index] == 0) continue;
            pc.output_ids[run.first_candidate + visible_count] = pc.candidates[candidate_index].packed_id;
            visible_count++;
        }
        run.instance_count = visible_count;
        pc.runs[index] = run;
        pc.commands[index].instance_count = visible_count;
        return;
    }
    if (index >= pc.candidate_count) return;

    CullCandidate candidate = pc.candidates[index];
    CullRun run = pc.runs[candidate.run_index];
    uint draw_id = candidate.packed_id >> INSTANCE_DRAW_ID_SHIFT;
    float4x4 world = pc.transforms[draw_id].model;
    float4 center4 = mul(world, float4(run.bounds_center.xyz, 1.0));
    float3 extents = run.bounds_extents.xyz;
    float3 world_extents = float3(
        abs(world[0][0]) * extents.x + abs(world[0][1]) * extents.y + abs(world[0][2]) * extents.z,
        abs(world[1][0]) * extents.x + abs(world[1][1]) * extents.y + abs(world[1][2]) * extents.z,
        abs(world[2][0]) * extents.x + abs(world[2][1]) * extents.y + abs(world[2][2]) * extents.z);
    for (uint p = 0; p < 6; ++p) {
        float4 plane = pc.planes[p];
        float radius = dot(world_extents, abs(plane.xyz));
        if (dot(plane.xyz, center4.xyz) - plane.w < -radius) {
            pc.output_ids[index] = 0;
            return;
        }
    }
    pc.output_ids[index] = 1;
}

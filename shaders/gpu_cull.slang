import types;

[[vk_push_constant]] CullPushConstants pc;

[shader("compute")]
[numthreads(256,1,1)]
void compute_main(uint3 dispatch_id : SV_DispatchThreadID) {
    uint index = dispatch_id.x;
    if (pc.init_commands != 0) {
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
        if (dot(plane.xyz, center4.xyz) - plane.w < -radius) return;
    }

    uint output_index;
    InterlockedAdd(pc.runs[candidate.run_index].instance_count, 1, output_index);
    pc.output_ids[run.first_candidate + output_index] = candidate.packed_id;
    InterlockedAdd(pc.commands[candidate.run_index].instance_count, 1);
}

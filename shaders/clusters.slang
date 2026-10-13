import types;

[[vk_push_constant]] ClusterPushConstants pc;

float3 view_position(float3 p, float4x4 view) {
    return mul(view, float4(p, 1.0)).xyz;
}

bool sphere_aabb(float3 center, float radius, float3 lo, float3 hi) {
    float3 delta = center - clamp(center, lo, hi);
    return dot(delta, delta) <= radius * radius;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void compute_main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= CLUSTER_COUNT) return;
    SceneData* scene = (SceneData*)pc.scene_data;
    ClusterHeader* headers = (ClusterHeader*)pc.clusters;
    uint* indices = (uint*)pc.indices;
    uint* counter = (uint*)pc.counter;
    uint x = id.x % CLUSTER_X;
    uint y = (id.x / CLUSTER_X) % CLUSTER_Y;
    uint z = id.x / (CLUSTER_X * CLUSTER_Y);
    float near_z = scene->cluster_near_far.x;
    float far_z = scene->cluster_near_far.y;
    float z0 = near_z * pow(far_z / near_z, float(z) / float(CLUSTER_Z));
    float z1 = near_z * pow(far_z / near_z, float(z + 1) / float(CLUSTER_Z));
    float2 uv0 = float2(x, y) / float2(CLUSTER_X, CLUSTER_Y);
    float2 uv1 = float2(x + 1, y + 1) / float2(CLUSTER_X, CLUSTER_Y);
    float2 ndc0 = uv0 * 2.0 - 1.0;
    float2 ndc1 = uv1 * 2.0 - 1.0;
    float4x4 proj = scene->proj;
    bool ortho = abs(proj[3][2]) < 1e-6;
    float sign_z = proj[3][2] < 0.0 || (ortho && proj[2][2] < 0.0) ? -1.0 : 1.0;
    float2 px0, px1, py0, py1;
    if (ortho) {
        px0 = (ndc0.x - proj[0][3]) / proj[0][0];
        px1 = (ndc1.x - proj[0][3]) / proj[0][0];
        py0 = (ndc0.y - proj[1][3]) / proj[1][1];
        py1 = (ndc1.y - proj[1][3]) / proj[1][1];
    } else {
        float scale = abs(proj[3][2]);
        px0 = ((ndc0.x * scale - proj[0][2] * sign_z) * float2(z0, z1) - proj[0][3]) / proj[0][0];
        px1 = ((ndc1.x * scale - proj[0][2] * sign_z) * float2(z0, z1) - proj[0][3]) / proj[0][0];
        py0 = ((ndc0.y * scale - proj[1][2] * sign_z) * float2(z0, z1) - proj[1][3]) / proj[1][1];
        py1 = ((ndc1.y * scale - proj[1][2] * sign_z) * float2(z0, z1) - proj[1][3]) / proj[1][1];
    }
    float3 lo = float3(min(min(px0.x, px0.y), min(px1.x, px1.y)), min(min(py0.x, py0.y), min(py1.x, py1.y)), z0);
    float3 hi = float3(max(max(px0.x, px0.y), max(px1.x, px1.y)), max(max(py0.x, py0.y), max(py1.x, py1.y)), z1);
    uint candidates[MAX_POINT_LIGHTS + MAX_SPOT_LIGHTS];
    uint count = 0;
    for (uint i = 0; i < scene->point_light_count; ++i) {
        PointLight light = scene->point_lights[i];
        float3 center = view_position(light.position_range.xyz, scene->view);
        center.z *= sign_z;
        if (sphere_aabb(center, light.position_range.w, lo, hi)) candidates[count++] = i;
    }
    for (uint i = 0; i < scene->spot_light_count; ++i) {
        SpotLight light = scene->spot_lights[i];
        float3 center = view_position(light.position_range.xyz, scene->view);
        center.z *= sign_z;
        if (sphere_aabb(center, light.position_range.w, lo, hi)) candidates[count++] = MAX_POINT_LIGHTS + i;
    }
    uint offset;
    InterlockedAdd(counter[0], count, offset);
    uint stored = offset < CLUSTER_INDEX_CAPACITY ? min(count, CLUSTER_INDEX_CAPACITY - offset) : 0;
    for (uint i = 0; i < stored; ++i) indices[offset + i] = candidates[i];
    headers[id.x].light_offset = min(offset, CLUSTER_INDEX_CAPACITY);
    headers[id.x].light_count = stored | (stored < count ? CLUSTER_OVERFLOW_BIT : 0);
}

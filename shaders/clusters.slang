import types;

[[vk_push_constant]] ClusterPushConstants pc;

float3 view_position(float3 p, float4x4 view) {
    return mul(view, float4(p, 1.0)).xyz;
}

bool sphere_aabb(float3 center, float radius, float3 lo, float3 hi) {
    float3 closest = clamp(center, lo, hi);
    float3 delta = center - closest;
    return dot(delta, delta) <= radius * radius;
}

[shader("compute")]
[numthreads(1, 1, 1)]
void compute_main(uint3 id : SV_DispatchThreadID) {
    SceneData* scene = (SceneData*)pc.scene_data;
    ClusterHeader* headers = (ClusterHeader*)pc.clusters;
    uint* indices = (uint*)pc.indices;

    float z0 = pc.near_far.x * pow(pc.near_far.y / pc.near_far.x, float(id.z) / float(CLUSTER_Z));
    float z1 = pc.near_far.x * pow(pc.near_far.y / pc.near_far.x, float(id.z + 1) / float(CLUSTER_Z));
    float2 uv0 = float2(id.xy) / float2(CLUSTER_X, CLUSTER_Y);
    float2 uv1 = float2(id.xy + 1) / float2(CLUSTER_X, CLUSTER_Y);
    float2 ndc0 = float2(uv0.x * 2.0 - 1.0, 1.0 - uv1.y * 2.0);
    float2 ndc1 = float2(uv1.x * 2.0 - 1.0, 1.0 - uv0.y * 2.0);
    bool orthographic = abs(scene->proj[3][2]) < 1e-6;
    float forward_sign = scene->proj[3][2] < 0.0 || (orthographic && scene->proj[2][2] < 0.0) ? -1.0 : 1.0;
    float projection_scale = orthographic ? 1.0 : abs(scene->proj[3][2]);
    float sx = projection_scale / scene->proj[0][0];
    float sy = projection_scale / scene->proj[1][1];
    float x0 = ndc0.x * z0 * sx, x1 = ndc0.x * z1 * sx;
    float x2 = ndc1.x * z0 * sx, x3 = ndc1.x * z1 * sx;
    float y0 = ndc0.y * z0 * sy, y1 = ndc0.y * z1 * sy;
    float y2 = ndc1.y * z0 * sy, y3 = ndc1.y * z1 * sy;
    float3 lo = float3(min(min(x0, x1), min(x2, x3)), min(min(y0, y1), min(y2, y3)), z0);
    float3 hi = float3(max(max(x0, x1), max(x2, x3)), max(max(y0, y1), max(y2, y3)), z1);

    uint cluster = id.x + id.y * CLUSTER_X + id.z * CLUSTER_X * CLUSTER_Y;
    uint offset = cluster * CLUSTER_LIGHT_CAPACITY;
    uint count = 0;
    for (uint i = 0; i < scene->point_light_count; ++i) {
        PointLight light = scene->point_lights[i];
        float3 center = view_position(light.position_range.xyz, scene->view);
        center.z *= forward_sign;
        if (sphere_aabb(center, light.position_range.w, lo, hi)) indices[offset + count++] = i;
    }
    for (uint i = 0; i < scene->spot_light_count; ++i) {
        SpotLight light = scene->spot_lights[i];
        float3 center = view_position(light.position_range.xyz, scene->view);
        center.z *= forward_sign;
        if (sphere_aabb(center, light.position_range.w, lo, hi)) indices[offset + count++] = MAX_POINT_LIGHTS + i;
    }
    headers[cluster].light_offset = offset;
    headers[cluster].light_count = count;
}

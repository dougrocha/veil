struct AmbientLight {
    float4 color;
    float brightness;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    float3 light_pos;
    float3 cam_pos;
    float delta_time;
    AmbientLight ambient_light;
};

struct Particle {
    float4 position;
    float4 velocity;
    float4 color;
};

struct ParticlePushConstants {
    SceneData* scene_data;
    Particle* particles_in;
    Particle* particles_out;
    float delta_time;
};
[[vk_push_constant]] ParticlePushConstants pc;

struct VSOutput {
    float4 pos        : SV_Position;
    float  pointSize  : SV_PointSize;
    float4 color      : COLOR0;
};

struct PSInput {
    float4 pos        : SV_POSITION;
    float4 color      : COLOR0;
    float2 pointCoord : SV_PointCoord;
};

[shader("vertex")]
VSOutput vertex_main(uint vertId : SV_VertexID) {
    Particle p = pc.particles_out[vertId];
    VSOutput output;
    output.pos       = mul(pc.scene_data.proj, mul(pc.scene_data.view, p.position));
    output.pointSize = 3.0;
    output.color     = p.color;
    return output;
}

[shader("fragment")]
float4 fragment_main(PSInput input) : SV_TARGET {
    float2 coord = input.pointCoord - float2(0.5);
    float alpha = input.color.a * (0.5 - length(coord));
    return float4(input.color.rgb, alpha);
}

[shader("compute")]
[numthreads(256,1,1)]
void compute_main(uint3 threadId : SV_DispatchThreadID) {
    uint index = threadId.x;

    Particle p = pc.particles_in[index];

    p.position.xyz += p.velocity.xyz * pc.delta_time;

    if (p.position.y < -1.0) {
        p.position.y = 15.0;
    }

    pc.particles_out[index] = p;
}

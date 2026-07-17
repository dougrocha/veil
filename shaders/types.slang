struct Vertex {
    float3 pos;
    float2 uv;
    float3 normal;
    float4 tangent; // xyz = tangent direction, w = handedness
};

struct AmbientLight {
    float4 color;
    float brightness;
};

struct PointLight {
    float3 pos;
    float constant;
    float3 color;
    float linear;
    float quadratic;
    float diffuse_intensity;
    float specular_intensity;
};

struct DirectionalLight {
    float3 direction;
    float3 color;
    float diffuse_intensity;
    float specular_intensity;
};

struct SpotLight {
    float3 pos;
    float inner_cutoff;
    float3 direction;
    float outer_cutoff;
    float3 color;
    float constant;
    float linear;
    float quadratic;
    float diffuse_intensity;
    float specular_intensity;
};

struct TimeInfo {
    float time;
    float delta_time;
    uint frame_count;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    float4x4 light_view_proj[6][6];
    float4x4 dir_light_view_proj[6];
    PointLight point_lights[16];
    DirectionalLight directional_lights[4];
    SpotLight spot_lights[4];
    float3 cam_pos;
    TimeInfo time_info;
    AmbientLight ambient_light;
    uint point_light_count;
    uint directional_light_count;
    uint spot_light_count;
    float shadow_near;
    float shadow_far;
};

struct Material {
    float4 base_color;
    float  perceptual_roughness;
    float  metallic;
    uint   base_color_texture;
    uint   metallic_roughness_texture;
    uint   normal_map_texture;
    uint   occlusion_texture;
};

struct Transform {
    float4x4 model;
    float4x4 normal_matrix;
};

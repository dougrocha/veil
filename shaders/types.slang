struct Vertex {
    float3 pos;
    float2 uv;
    float3 color;
    float3 normal;
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

struct SceneData {
    float4x4 view;
    float4x4 proj;
    PointLight point_lights[16];
    DirectionalLight directional_lights[4];
    SpotLight spot_lights[4];
    float3 cam_pos;
    float delta_time;
    AmbientLight ambient_light;
    uint point_light_count;
    uint directional_light_count;
    uint spot_light_count;
};

struct Material {
    float4 base_color;
    uint base_color_texture;
    // for PBR RENDERING LATER, we are doing phong for now
    // float metallic;
    // float roughness;
    // float3 emissive;
    // uint metallic_texture;
    // uint normal_texture;
    // uint roughness_texture;
    // uint emissive_texture;
};

struct Transform {
    float4x4 model;
    float4x4 normal_matrix;
};

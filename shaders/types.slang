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
    float range;
    float shadow_near;
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
    float range;
    float shadow_near;
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

static const uint MAX_POINT_LIGHTS = 16;
static const uint MAX_DIRECTIONAL_LIGHTS = 4;
static const uint MAX_SPOT_LIGHTS = 4;
static const uint SHADOW_MAP_CASCADE_COUNT = 4;
// 2D shadow atlas holds directional lights first (cascaded), then spot lights.
static const uint MAX_SHADOW_2D_SLOTS = (MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT) + MAX_SPOT_LIGHTS;

struct DebugSettings {
    uint show_cascades;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    float3 cam_pos;
    TimeInfo time_info;

    // lights and shadows
    PointLight point_lights[MAX_POINT_LIGHTS];
    uint point_light_count;
    DirectionalLight directional_lights[MAX_DIRECTIONAL_LIGHTS];
    uint directional_light_count;
    SpotLight spot_lights[MAX_SPOT_LIGHTS];
    uint spot_light_count;
    AmbientLight ambient_light;
    float shadow_map_size;
    float4x4 point_light_view_proj[MAX_POINT_LIGHTS][6];
    float4x4 shadow_2d_view_proj[MAX_SHADOW_2D_SLOTS];
    ShadowCascadeData shadow_cascade_data[MAX_DIRECTIONAL_LIGHTS];

    // debug
    DebugSettings debug_settings;
};

struct ShadowCascadeData {
	float4 split;
	float4 bias;
}

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

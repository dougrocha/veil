// Generated from src/graphics/gpu_types.odin. Do not edit.

static const uint MAX_POINT_LIGHTS = 8;
static const uint MAX_DIRECTIONAL_LIGHTS = 2;
static const uint MAX_SPOT_LIGHTS = 4;
static const uint SHADOW_MAP_CASCADE_COUNT = 4;
static const uint MAX_SHADOW_2D_SLOTS = (((MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT)) + MAX_SPOT_LIGHTS);
static const uint LIGHT_MASK_POINT = 1;
static const uint LIGHT_MASK_DIRECTIONAL = 2;
static const uint LIGHT_MASK_SPOT = 4;
static const uint LIGHT_MASK_ALL = 7;
static const uint SAMPLER_LINEAR_REPEAT = 0;
static const uint SAMPLER_LINEAR_CLAMP = 1;
static const uint SAMPLER_NEAREST_CLAMP = 2;
static const uint BINDLESS_SAMPLER_COUNT = 3;
static const uint BINDLESS_STORAGE_IMAGE_COUNT = 16;
static const uint BINDLESS_CUBE_COUNT = 16;

struct Vertex {
    float4 pos;
    float2 uv;
    float2 _pad1;
    float4 normal;
    float4 tangent;
};

struct AmbientLight {
    float4 color_brightness;
};

struct PointLight {
    float4 position_range;
    float4 color_shadow_near;
    float4 attenuation_diffuse;
    float4 specular_reserved;
};

struct DirectionalLight {
    float4 direction_diffuse;
    float4 color_specular;
    float4 shadow_maximum_reserved;
};

struct SpotLight {
    float4 position_range;
    float4 direction_inner;
    float4 color_outer;
    float4 attenuation;
    float4 intensity;
};

struct TimeInfo {
    float time;
    float delta_time;
    uint frame_count;
    uint _reserved;
};

struct DebugSettings {
    uint show_cascades;
    uint disable_shadows;
    uint light_mask;
    uint _reserved;
};

struct ShadowCascadeData {
    float4 split;
    float4 bias;
};

struct Transform {
    float4x4 model;
    float4x4 normal_matrix;
};

struct Material {
    float4 base_color;
    float perceptual_roughness;
    float metallic;
    uint base_color_texture;
    uint metallic_roughness_texture;
    uint normal_map_texture;
    uint occlusion_texture;
    uint alpha_mode;
    float alpha_cutoff;
    float4 emissive;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    float4x4 point_light_view_proj[6][MAX_POINT_LIGHTS];
    float4x4 shadow_2d_view_proj[MAX_SHADOW_2D_SLOTS];
    ShadowCascadeData shadow_cascade_data[MAX_DIRECTIONAL_LIGHTS];
    float4 cam_pos_shadow_map_size;
    TimeInfo time_info;
    PointLight point_lights[MAX_POINT_LIGHTS];
    uint point_light_count;
    uint directional_light_count;
    uint spot_light_count;
    uint skybox_cube;
    DirectionalLight directional_lights[MAX_DIRECTIONAL_LIGHTS];
    SpotLight spot_lights[MAX_SPOT_LIGHTS];
    AmbientLight ambient_light;
    DebugSettings debug_settings;
};

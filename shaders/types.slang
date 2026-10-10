// Generated from the @(shader_shared) declarations in src/graphics. Do not edit.

static const uint SAMPLER_LINEAR_REPEAT = 0;
static const uint SAMPLER_LINEAR_CLAMP = 1;
static const uint SAMPLER_NEAREST_CLAMP = 2;
static const uint BINDLESS_SAMPLER_COUNT = 3;
static const uint BINDLESS_STORAGE_IMAGE_COUNT = 16;
static const uint BINDLESS_CUBE_COUNT = 16;
static const uint INSTANCE_MATERIAL_BITS = 14;
static const uint INSTANCE_MATERIAL_MASK = (((1 << INSTANCE_MATERIAL_BITS)) - 1);
static const uint INSTANCE_DRAW_ID_SHIFT = INSTANCE_MATERIAL_BITS;
static const uint INSTANCE_DRAW_ID_BITS = 15;
static const uint MAX_POINT_LIGHTS = 512;
static const uint MAX_DIRECTIONAL_LIGHTS = 2;
static const uint MAX_SPOT_LIGHTS = 32;
static const uint POST_GROUP_SIZE = 8;
static const uint MAX_POINT_SHADOW_LIGHTS = 8;
static const uint SHADOW_MAP_CASCADE_COUNT = 4;
static const uint POINT_SHADOW_MAP_SIZE = 1024;
static const uint MAX_SHADOW_2D_SLOTS = (((MAX_DIRECTIONAL_LIGHTS * SHADOW_MAP_CASCADE_COUNT)) + MAX_SPOT_LIGHTS);
static const uint PARTICLE_GROUP_SIZE = 256;

static const uint DEBUG_VIEW_MODE_TEXTURE_2D = 0;
static const uint DEBUG_VIEW_MODE_SHADOW_CUBE_FACE = 1;
static const uint DEBUG_VIEW_MODE_SHADOW_2D = 2;

static const uint LIGHT_TYPE_DIRECTIONAL = 0;
static const uint LIGHT_TYPE_SPOT = 1;
static const uint LIGHT_TYPE_POINT = 2;

static const uint ALPHA_MODE_OPAQUE = 0;
static const uint ALPHA_MODE_MASK = 1;
static const uint ALPHA_MODE_BLEND = 2;

struct StorageImageIndex {
    uint value;
};

struct TextureIndex {
    uint value;
};

struct CubeIndex {
    uint value;
};

struct Particle {
    float4 position;
    float4 velocity;
    float4 color;
};

struct ShadowCascadeData {
    float4 split;
    float4 bias;
};

struct TimeInfo {
    float time;
    float delta_time;
    uint frame_count;
    uint _reserved;
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

struct AmbientLight {
    float4 color_brightness;
};

struct DebugSettings {
    uint show_cascades;
    uint disable_shadows;
    uint light_mask;
    uint _reserved;
};

struct SceneData {
    float4x4 view;
    float4x4 proj;
    float4x4 point_light_view_proj[6][MAX_POINT_SHADOW_LIGHTS];
    float4x4 shadow_2d_view_proj[MAX_SHADOW_2D_SLOTS];
    ShadowCascadeData shadow_cascade_data[MAX_DIRECTIONAL_LIGHTS];
    float4 cam_pos_shadow_map_size;
    TimeInfo time_info;
    PointLight point_lights[MAX_POINT_LIGHTS];
    uint point_light_count;
    uint directional_light_count;
    uint spot_light_count;
    CubeIndex skybox_cube;
    DirectionalLight directional_lights[MAX_DIRECTIONAL_LIGHTS];
    SpotLight spot_lights[MAX_SPOT_LIGHTS];
    AmbientLight ambient_light;
    DebugSettings debug_settings;
};

struct ParticlePushConstants {
    SceneData* scene_data;
    Particle* particles_in;
    Particle* particles_out;
    float delta_time;
};

struct DebugViewPushConstants {
    uint mode;
    uint index;
    uint face;
};

struct SkyboxPushConstants {
    SceneData* scene_data;
};

struct Transform {
    float4x4 model;
    float4x4 normal_matrix;
};

struct DrawIndexedIndirectCommand {
    uint index_count;
    uint instance_count;
    uint first_index;
    int vertex_offset;
    uint first_instance;
};

struct LineVertex {
    float4 position;
    float4 color;
};

struct LinePushConstants {
    SceneData* scene_data;
    LineVertex* vertex_buffer;
    float2 screen_size;
    float thickness;
};

struct Material {
    float4 base_color;
    float4 emissive;
    float perceptual_roughness;
    float metallic;
    TextureIndex base_color_texture;
    TextureIndex metallic_roughness_texture;
    TextureIndex normal_map_texture;
    TextureIndex occlusion_texture;
    uint alpha_mode;
    float alpha_cutoff;
    uint double_sided;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

struct Vertex {
    float4 pos_uv_x;
    float4 normal_uv_y;
    float4 tangent;
};

struct MeshPushConstants {
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Material* material_buffer;
    Transform* transform_buffer;
    uint* instance_ids;
};

struct TonemapPushConstants {
    TextureIndex hdr_texture;
    StorageImageIndex out_storage;
    float exposure;
    TextureIndex bloom_texture;
    float bloom_strength;
};

struct BloomPushConstants {
    TextureIndex src_texture;
    StorageImageIndex dst_storage;
    float2 src_texel_size;
    uint karis;
    float radius;
};

struct ShadowPushConstants {
    float4x4 view_proj;
    SceneData* scene_data;
    Vertex* vertex_buffer;
    Material* material_buffer;
    Transform* transform_buffer;
    uint* instance_ids;
    uint light_type;
    uint light_index;
};

struct UIVertex {
    float2 position;
    float2 uv;
    uint color;
    uint _pad0;
};

struct UIPushConstants {
    UIVertex* vertex_buffer;
    float2 screen_size;
    TextureIndex atlas_texture;
};

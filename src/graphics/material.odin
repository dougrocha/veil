package graphics

import "core:log"
import "core:strings"

import "backend"

@(shader_shared)
AlphaMode :: enum u32 {
	Opaque,
	Mask,
	Blend,
}

@(shader_shared)
GpuMaterial :: struct #max_field_align(16) {
	base_color:                 Vec4,
	emissive:                   Vec4, // rgb: unbounded HDR emitted color, added after lighting; w unused
	perceptual_roughness:       f32,
	metallic:                   f32,
	base_color_texture:         TextureIndex,
	metallic_roughness_texture: TextureIndex,
	normal_map_texture:         TextureIndex,
	occlusion_texture:          TextureIndex,
	alpha_mode:                 AlphaMode,
	alpha_cutoff:               f32,
	double_sided:               u32, // back faces are drawn and lit with the normal flipped
	_pad0:                      u32,
	_pad1:                      u32,
	_pad2:                      u32,
}

DEFAULT_MATERIAL_NAME :: "default"

MAX_MATERIALS :: 16384

Material :: struct {
	name:                       string,
	base_color:                 Vec4,
	perceptual_roughness:       f32,
	metallic:                   f32,
	base_color_texture:         TextureHandle,
	metallic_roughness_texture: TextureHandle,
	normal_map_texture:         TextureHandle,
	occlusion_texture:          TextureHandle,
	alpha_mode:                 AlphaMode,
	alpha_cutoff:               f32,
	emissive:                   Vec3,
	double_sided:               bool, // no back-face culling; back faces lit with the normal flipped
}

MaterialHandle :: Handle(Material)
INVALID_MATERIAL :: MaterialHandle{}

MaterialSystemConfig :: struct {
	max_material_count: u32,
}

MaterialSystem :: struct {
	materials:    Pool(Material),
	material_map: map[string]MaterialHandle,
	buffer:       backend.Buffer(GpuMaterial),
	config:       MaterialSystemConfig,
}

material_system_create :: proc(engine: ^Engine, config: MaterialSystemConfig) {
	engine.material_system.config = config
	engine.material_system.materials = pool_init(config.max_material_count, Material)
	engine.material_system.material_map = make(map[string]MaterialHandle)

	engine.material_system.buffer = backend.buffer_create(
		GpuMaterial,
		&engine.vk_ctx,
		int(config.max_material_count),
		{.Storage},
		.Shared,
	)

	material_create_default(engine)
}

material_create :: proc(
	engine: ^Engine,
	key: string,
	base_color: Vec4 = {1, 1, 1, 1},
	perceptual_roughness: f32 = 0,
	metallic: f32 = 0,
	base_color_texture: TextureHandle = INVALID_TEXTURE,
	metallic_roughness_texture: TextureHandle = INVALID_TEXTURE,
	normal_map_texture: TextureHandle = INVALID_TEXTURE,
	occlusion_texture: TextureHandle = INVALID_TEXTURE,
	alpha_mode: AlphaMode = .Opaque,
	alpha_cutoff: f32 = 0.5,
	emissive: Vec3 = {0, 0, 0}, // HDR, bake the strength in (e.g. color * 20)
	double_sided := false,
	display_name := "", // defaults to key; the key is identity, the display name is only for UI
) -> MaterialHandle {
	if handle, ok := engine.material_system.material_map[key]; ok {
		log.warnf("Material \"%s\" already exists; returning existing material", key)
		return handle
	}

	if engine.material_system.materials.count >= engine.material_system.config.max_material_count {
		log.errorf("Material system is full (max: %d)", engine.material_system.config.max_material_count)
		return INVALID_MATERIAL
	}

	log.debugf("Creating material: %s", key)
	// Owned copies: the map key lives until material_system_destroy; callers pass temp strings.
	map_key := strings.clone(key)
	name := strings.clone(display_name if display_name != "" else key)
	resolve :: proc(engine: ^Engine, key: string, h: TextureHandle, default: DefaultTexture) -> TextureHandle {
		if h == INVALID_TEXTURE do return texture_load(engine, default)
		if pool_is_valid(&engine.texture_system.textures, h) do return h
		log.warnf(
			"Material \"%s\": texture handle (index %d, generation %d) is stale; using default",
			key,
			h.index,
			h.generation,
		)
		return texture_load(engine, default)
	}
	resolved_base_color := resolve(engine, key, base_color_texture, .White)
	resolved_metallic_roughness := resolve(engine, key, metallic_roughness_texture, .Metallic_Roughness)
	resolved_normal := resolve(engine, key, normal_map_texture, .Flat_Normal)
	resolved_occlusion := resolve(engine, key, occlusion_texture, .Occlusion)

	material := Material {
		name                       = name,
		base_color                 = base_color,
		perceptual_roughness       = perceptual_roughness,
		metallic                   = metallic,
		base_color_texture         = resolved_base_color,
		metallic_roughness_texture = resolved_metallic_roughness,
		normal_map_texture         = resolved_normal,
		occlusion_texture          = resolved_occlusion,
		alpha_mode                 = alpha_mode,
		alpha_cutoff               = alpha_cutoff,
		emissive                   = emissive,
		double_sided               = double_sided,
	}

	handle := pool_alloc(&engine.material_system.materials, material)
	engine.material_system.material_map[map_key] = handle

	gpu_mat := GpuMaterial {
		base_color                 = base_color,
		perceptual_roughness       = perceptual_roughness,
		metallic                   = metallic,
		base_color_texture         = texture_index(resolved_base_color),
		metallic_roughness_texture = texture_index(resolved_metallic_roughness),
		normal_map_texture         = texture_index(resolved_normal),
		occlusion_texture          = texture_index(resolved_occlusion),
		alpha_mode                 = alpha_mode,
		alpha_cutoff               = alpha_cutoff,
		double_sided               = u32(double_sided),
		emissive                   = {emissive.x, emissive.y, emissive.z, 0},
	}
	backend.buffer_write(&engine.vk_ctx, engine.material_system.buffer, gpu_mat, int(handle.index))

	return handle
}

material_system_destroy :: proc(engine: ^Engine) {
	ms := &engine.material_system
	backend.buffer_destroy(&engine.vk_ctx, ms.buffer)
	for &material, i in ms.materials.values {
		if pool_is_alive(&ms.materials, Index(i)) do delete(material.name)
	}
	for key in ms.material_map do delete(key)
	pool_destroy(&ms.materials)
	delete(ms.material_map)
}

material_get_default :: proc(engine: ^Engine) -> MaterialHandle {
	return engine.material_system.material_map[DEFAULT_MATERIAL_NAME]
}

material_create_default :: proc(engine: ^Engine) {
	material_create(
		engine,
		DEFAULT_MATERIAL_NAME,
		perceptual_roughness = 0.5,
		base_color_texture = texture_load(engine, DefaultTexture.White),
		metallic_roughness_texture = texture_load(engine, DefaultTexture.Metallic_Roughness),
		normal_map_texture = texture_load(engine, DefaultTexture.Flat_Normal),
		occlusion_texture = texture_load(engine, DefaultTexture.Occlusion),
	)
}

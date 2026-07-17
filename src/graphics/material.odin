package graphics

import "core:log"
import "core:mem"

import "backend"

DEFAULT_MATERIAL_NAME :: "default"

MAX_MATERIALS :: 1024

GpuMaterial :: struct {
	base_color:                 Vec4,
	perceptual_roughness:       f32,
	metallic:                   f32,
	base_color_texture:         u32,
	metallic_roughness_texture: u32,
	normal_map_texture:         u32,
	occlusion_texture:          u32,
}

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
}

MaterialHandle :: Handle(Material)
INVALID_MATERIAL :: MaterialHandle{}

MaterialSystemConfig :: struct {
	max_material_count: u32,
}

MaterialSystem :: struct {
	materials:    Pool(Material),
	material_map: map[string]MaterialHandle,
	buffer:       backend.GpuBuffer(GpuMaterial),
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
		.MappedStorage,
	)

	material_create_default(engine)
}

material_create :: proc(
	engine: ^Engine,
	name: string,
	base_color: Vec4 = {1, 1, 1, 1},
	perceptual_roughness: f32 = 0,
	metallic: f32 = 0,
	base_color_texture: TextureHandle = INVALID_TEXTURE,
	metallic_roughness_texture: TextureHandle = INVALID_TEXTURE,
	normal_map_texture: TextureHandle = INVALID_TEXTURE,
	occlusion_texture: TextureHandle = INVALID_TEXTURE,
	alpha_mode: AlphaMode = .Opaque,
) -> MaterialHandle {
	if handle, ok := engine.material_system.material_map[name]; ok {
		log.warnf("Material \"%s\" already exists; returning existing material", name)
		return handle
	}

	if engine.material_system.materials.count >= engine.material_system.config.max_material_count {
		log.errorf("Material system is full (max: %d)", engine.material_system.config.max_material_count)
		return INVALID_MATERIAL
	}

	log.debugf("Creating material: %s", name)

	material := Material {
		name                       = name,
		base_color                 = base_color,
		perceptual_roughness       = perceptual_roughness,
		metallic                   = metallic,
		base_color_texture         = base_color_texture,
		metallic_roughness_texture = metallic_roughness_texture,
		normal_map_texture         = normal_map_texture,
		occlusion_texture          = occlusion_texture,
		alpha_mode                 = alpha_mode,
	}

	handle := pool_alloc(&engine.material_system.materials, material)
	engine.material_system.material_map[name] = handle

	ts := &engine.texture_system
	resolve :: proc(h, default: TextureHandle) -> u32 {
		return h.index if h != INVALID_TEXTURE else default.index
	}

	offset := uintptr(handle.index) * size_of(GpuMaterial)
	dst := uintptr(engine.material_system.buffer.alloc_info.mapped_data) + offset
	gpu_mat := GpuMaterial {
		base_color                 = base_color,
		perceptual_roughness       = perceptual_roughness,
		metallic                   = metallic,
		base_color_texture         = resolve(base_color_texture, texture_load(engine, DefaultTexture.White)),
		metallic_roughness_texture = resolve(
			metallic_roughness_texture,
			texture_load(engine, DefaultTexture.Metallic_Roughness),
		),
		normal_map_texture         = resolve(normal_map_texture, texture_load(engine, DefaultTexture.Flat_Normal)),
		occlusion_texture          = resolve(occlusion_texture, texture_load(engine, DefaultTexture.Occlusion)),
	}
	mem.copy(rawptr(dst), &gpu_mat, size_of(GpuMaterial))

	return handle
}

material_system_destroy :: proc(engine: ^Engine) {
	ms := &engine.material_system
	backend.buffer_destroy(&engine.vk_ctx, ms.buffer)
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

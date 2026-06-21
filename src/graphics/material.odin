package graphics

import "core:log"
import "core:mem"

import vk "vendor:vulkan"

DEFAULT_MATERIAL_NAME :: "default"

MAX_MATERIALS :: 1024

GpuMaterial :: struct {
	base_color:         Vec4,
	// metallic:                 f32,
	// roughness:                f32,
	// emissive:                 Vec3,
	base_color_texture: u32,
	// metallic_texture:      u32,
	// normal_texture:        u32,
	// roughness_texture:     u32,
	// emissive_texture:      u32,
}

Material :: struct {
	base_color:         Vec4,
	base_color_texture: TextureHandle,
	alpha_mode:         AlphaMode,
}

MaterialHandle :: Handle(Material)

INVALID_MATERIAL :: MaterialHandle{}

MaterialSystemConfig :: struct {
	max_material_count: u32,
}

MaterialSystem :: struct {
	materials:    Pool(Material),
	material_map: map[string]MaterialHandle,
	buffer:       GpuBuffer,
	config:       MaterialSystemConfig,
}

create_material_system :: proc(engine: ^Engine, config: MaterialSystemConfig) {
	engine.material_system.config = config
	engine.material_system.materials = pool_init(config.max_material_count, Material)
	engine.material_system.material_map = make(map[string]MaterialHandle)

	total_size := vk.DeviceSize(size_of(GpuMaterial) * u64(config.max_material_count))
	engine.material_system.buffer = create_buffer(&engine.vk_ctx, total_size, .MappedStorage)

	create_default_material(engine)
}

create_material :: proc(engine: ^Engine, name: string, material: Material) -> MaterialHandle {
	if handle, ok := engine.material_system.material_map[name]; ok {
		return handle
	}

	if engine.material_system.materials.count >= engine.material_system.config.max_material_count {
		log.errorf("Material system is full (max: %d)", engine.material_system.config.max_material_count)
		return INVALID_MATERIAL
	}

	handle := pool_alloc(&engine.material_system.materials, material)
	engine.material_system.material_map[name] = handle

	offset := uintptr(handle.index) * size_of(GpuMaterial)
	dst := uintptr(engine.material_system.buffer.alloc_info.mapped_data) + offset
	gpu_mat := GpuMaterial {
		base_color         = material.base_color,
		base_color_texture = material.base_color_texture.index,
	}
	mem.copy(rawptr(dst), &gpu_mat, size_of(GpuMaterial))

	return handle
}

destroy_material_system :: proc(engine: ^Engine) {
	ms := &engine.material_system
	destroy_buffer(&engine.vk_ctx, ms.buffer)
	pool_destroy(&ms.materials)
	delete(ms.material_map)
}

get_default_material :: proc(engine: ^Engine) -> MaterialHandle {
	return engine.material_system.material_map[DEFAULT_MATERIAL_NAME]
}

create_default_material :: proc(engine: ^Engine) {
	create_material(
		engine,
		DEFAULT_MATERIAL_NAME,
		Material{base_color = {1, 1, 1, 1}, base_color_texture = get_default_texture(engine)},
	)
}

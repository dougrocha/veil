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
	base_color_texture: TextureHandle,
	// metallic_texture:      TextureHandle,
	// normal_texture:        TextureHandle,
	// roughness_texture:     TextureHandle,
	// emissive_texture:      TextureHandle,
}

Material :: struct {
	using gpu:  GpuMaterial,
	alpha_mode: AlphaMode,
}

MaterialHandle :: struct {
	handle: u32,
}

INVALID_MATERIAL :: MaterialHandle {
	handle = max(u32),
}

MaterialSystemConfig :: struct {
	max_material_count: u32,
}

MaterialSystem :: struct {
	materials:    [dynamic]Material,
	material_map: map[string]MaterialHandle,
	buffer:       GpuBuffer,
	config:       MaterialSystemConfig,
}

create_material_system :: proc(engine: ^Engine, config: MaterialSystemConfig) {
	engine.material_system.config = config

	total_size := vk.DeviceSize(size_of(GpuMaterial) * u64(config.max_material_count))
	engine.material_system.buffer = create_buffer(engine, total_size, .MappedStorage)

	create_default_material(engine)
}

create_material :: proc(engine: ^Engine, name: string, material: Material) -> MaterialHandle {
	if handle, ok := engine.material_system.material_map[name]; ok {
		return handle
	}

	if u32(len(engine.material_system.materials)) >= engine.material_system.config.max_material_count {
		log.errorf("Material system is full (max: %d)", engine.material_system.config.max_material_count)
		return INVALID_MATERIAL
	}

	index := u32(len(engine.material_system.materials))
	append(&engine.material_system.materials, material)
	engine.material_system.material_map[name] = MaterialHandle {
		handle = index,
	}

	offset := uintptr(index) * size_of(GpuMaterial)
	dst := uintptr(engine.material_system.buffer.alloc_info.mapped_data) + offset
	mat := material.gpu
	mem.copy(rawptr(dst), &mat, size_of(GpuMaterial))

	return MaterialHandle{handle = index}
}

destroy_material_system :: proc(engine: ^Engine) {
	ms := &engine.material_system
	destroy_buffer(engine, ms.buffer)
	delete(ms.materials)
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

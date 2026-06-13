package graphics

import "core:log"
import "core:mem"

import vk "vendor:vulkan"

DEFAULT_MATERIAL_NAME :: "default"

MAX_MATERIALS :: 100

Material :: struct {
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
	total_size := vk.DeviceSize(size_of(Material) * u64(config.max_material_count))
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

	offset := uintptr(index) * size_of(Material)
	dst := uintptr(engine.material_system.buffer.alloc_info.mapped_data) + offset
	// cannot take addresses of proc args, so gotta do this
	mat := material
	mem.copy(rawptr(dst), &mat, size_of(Material))

	return MaterialHandle{handle = index}
}

destroy_material_system :: proc(engine: ^Engine) {
	ms := &engine.material_system
	destroy_buffer(engine, ms.buffer)
	delete(ms.materials)
	delete(ms.material_map)
}

create_default_material :: proc(engine: ^Engine) {
	create_material(
		engine,
		DEFAULT_MATERIAL_NAME,
		Material{base_color = {1, 1, 1, 1}, base_color_texture = {handle = 0}},
	)
}

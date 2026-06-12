package graphics

import vk "vendor:vulkan"

create_default_material :: proc(engine: ^Engine) {
	default_mat := Material {
		base_color               = {1, 1, 1, 1},
		metallic                 = 0,
		roughness                = 1,
		base_color_texture_index = 0,
		metallic_texture_index   = -1,
		normal_texture_index     = -1,
		roughness_texture_index  = -1,
		emissive_texture_index   = -1,
	}
	append(&engine.materials, default_mat)
}

create_material_buffer :: proc(engine: ^Engine) {
	if len(engine.materials) == 0 do return
	total_size := vk.DeviceSize(size_of(Material) * len(engine.materials))

	buf := upload_buffer(engine, raw_data(engine.materials[:]), total_size, .Storage)
	engine.material_buffer = buf
}


package graphics

import vk "vendor:vulkan"

create_material_buffer :: proc(engine: ^Engine) {
	if len(engine.materials) == 0 do return
	total_size := vk.DeviceSize(size_of(Material) * len(engine.materials))

	buf := buffer_upload(engine, raw_data(engine.materials[:]), total_size, .Storage)
	engine.material_buffer = buf
}


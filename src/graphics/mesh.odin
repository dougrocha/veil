package graphics

import "core:log"
import "core:math/linalg"
import "core:mem"

import vma "shared:odin-vma"
import "shared:tinyobj"
import vk "vendor:vulkan"

load_model :: proc(engine: ^Engine, path: string) {
	obj, ok := tinyobj.load_from_file_path(path, allocator = context.temp_allocator)

	if !ok {
		log.errorf("Failed to read model from {}", path)
		return
	}

	vertices := make([dynamic]Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)

	unique_vertices := make(map[Vertex]u32)

	for shape in obj.shapes {
		for index in obj.attrib.faces[shape.face_offset:shape.face_offset + shape.length] {
			normal: Vec3 = {0.0, 1.0, 0.0}
			if index.v_idx != tinyobj.INVALID_INDEX {
				normal = {
					obj.attrib.normals[3 * index.vn_idx + 0],
					obj.attrib.normals[3 * index.vn_idx + 1],
					obj.attrib.normals[3 * index.vn_idx + 2],
				}
			}

			vertex := Vertex {
				pos       = {
					obj.attrib.vertices[3 * index.v_idx + 0],
					obj.attrib.vertices[3 * index.v_idx + 1],
					obj.attrib.vertices[3 * index.v_idx + 2],
				},
				tex_coord = {
					obj.attrib.texcoords[2 * index.vt_idx + 0],
					1.0 - obj.attrib.texcoords[2 * index.vt_idx + 1],
				},
				color     = {1, 1, 1},
				normal    = normal,
			}

			_, val, inserted, _ := map_entry(&unique_vertices, vertex)

			if inserted {
				val^ = u32(len(vertices))
				append(&vertices, vertex)
			}

			append(&indices, val^)
		}
	}

	vertex_size := vk.DeviceSize(size_of(Vertex) * len(vertices))
	index_size := vk.DeviceSize(size_of(u32) * len(indices))

	vertex_buffer, vertex_allocation := upload_buffer(
		engine,
		raw_data(vertices[:]),
		vertex_size,
		{.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
	)
	index_buffer, index_allocation := upload_buffer(engine, raw_data(indices[:]), index_size, {.INDEX_BUFFER})

	addr_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = vertex_buffer,
	}
	vertex_address := vk.GetBufferDeviceAddress(engine.device, &addr_info)

	material_index := i32(len(engine.materials))
	append(&engine.materials, Material{base_color = {1, 1, 1, 1}, base_color_texture_index = 1})
	create_material_buffer(engine)

	correction := linalg.quaternion_angle_axis_f32(linalg.to_radians(f32(-90)), Vec3{1, 0, 0})
	append(
		&engine.meshes,
		Mesh {
			vertex_buffer = vertex_buffer,
			vertex_allocation = vertex_allocation,
			vertex_address = vertex_address,
			index_buffer = index_buffer,
			index_allocation = index_allocation,
			index_count = u32(len(indices)),
			material_index = material_index,
			transform = Transform{rotation = correction},
		},
	)
}

upload_buffer :: proc(
	engine: ^Engine,
	data: rawptr,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
) -> (
	vk.Buffer,
	vma.Allocation,
) {
	staging_buffer: vk.Buffer
	staging_allocation: vma.Allocation
	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
			vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = size, usage = {.TRANSFER_SRC}},
			vma.Allocation_Create_Info{usage = .Auto, flags = {.Host_Access_Sequential_Write}},
			&staging_buffer,
			&staging_allocation,
			nil,
		),
	)
	defer vma.destroy_buffer(engine.vma_allocator, staging_buffer, staging_allocation)

	mapped: rawptr
	vk_check(vma.map_memory(engine.vma_allocator, staging_allocation, &mapped))
	mem.copy(mapped, data, int(size))
	vma.unmap_memory(engine.vma_allocator, staging_allocation)

	buf: vk.Buffer
	alloc: vma.Allocation
	vk_check(
		vma.create_buffer(
			engine.vma_allocator,
			vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = size, usage = usage + {.TRANSFER_DST}},
			vma.Allocation_Create_Info{usage = .Auto, required_flags = {.DEVICE_LOCAL}},
			&buf,
			&alloc,
			nil,
		),
	)

	copy_buffer(engine, staging_buffer, buf, size)
	return buf, alloc
}

vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
}

vertex_attribute_descriptions :: proc() -> [4]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, color))},
		{location = 3, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, normal))},
		{location = 2, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, tex_coord))},
	}
}


package graphics

import "core:log"

import "shared:tinyobj"

load_model :: proc(engine: ^Engine) {
	MODEL_PATH :: "models/viking_room.obj"

	obj, ok := tinyobj.load_from_file_path(MODEL_PATH, allocator = context.temp_allocator)

	if !ok {
		log.errorf("Failed to read model from {}", MODEL_PATH)
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

	engine.vertices = vertices[:]
	engine.indices = indices[:]
}


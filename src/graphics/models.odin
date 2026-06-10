package graphics

import "core:log"
import "core:math/linalg"

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

	material_index := i32(len(engine.materials))
	append(&engine.materials, Material{base_color = {1, 1, 1, 1}, base_color_texture_index = 1})

	correction := linalg.quaternion_angle_axis_f32(linalg.to_radians(f32(-90)), Vec3{1, 0, 0})
	append(&engine.meshes, Mesh{
		vertices       = vertices[:],
		indices        = indices[:],
		material_index = material_index,
		transform      = Transform{rotation = correction},
	})
}


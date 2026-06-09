package tinyobj

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"

FLAG_TRIANGULATE :: 1 << 0
INVALID_INDEX :: 0x80000000

Shape :: struct {
	name:        string,
	face_offset: int,
	length:      int,
}

Vertex_Index :: struct {
	v_idx:  int,
	vt_idx: int,
	vn_idx: int,
}

Attrib :: struct {
	vertices:  [dynamic]f32, // 3 floats per vertex
	normals:   [dynamic]f32, // 3 floats per normal
	texcoords: [dynamic]f32, // 2 floats per texcoord
	faces:     [dynamic]Vertex_Index,
}

OBJ :: struct {
	attrib: Attrib,
	shapes: [dynamic]Shape,
}

@(private)
fix_index :: proc(idx: int, n: int) -> int {
	if idx > 0 do return idx - 1
	if idx == 0 do return 0
	return n + idx
}

@(private)
parse_float :: proc(s: string) -> f32 {
	val, _ := strconv.parse_f32(s)
	return val
}

@(private)
parse_int :: proc(s: string) -> int {
	val, _ := strconv.parse_int(s)
	return val
}

load_from_file_path :: proc(
	path: string,
	flags: u32 = FLAG_TRIANGULATE,
	allocator := context.allocator,
) -> (
	obj: OBJ,
	ok: bool,
) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}

	obj.attrib.vertices = make([dynamic]f32, allocator)
	obj.attrib.normals = make([dynamic]f32, allocator)
	obj.attrib.texcoords = make([dynamic]f32, allocator)
	obj.attrib.faces = make([dynamic]Vertex_Index, allocator)
	obj.shapes = make([dynamic]Shape, allocator)

	triangulate := (flags & FLAG_TRIANGULATE) != 0

	current_shape_name := ""
	face_count := 0
	prev_shape_face_offset := 0
	v_count, vn_count, vt_count := 0, 0, 0

	commit_shape :: proc(obj: ^OBJ, name: string, offset: int, length: int, allocator: runtime.Allocator) {
		if length > 0 {
			append(&obj.shapes, Shape{name = strings.clone(name, allocator), face_offset = offset, length = length})
		}
	}

	buf := string(data)
	it := buf
	for line in strings.split_lines_iterator(&it) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' do continue

		parts := strings.fields(trimmed)
		defer delete(parts)
		if len(parts) == 0 do continue

		switch parts[0] {
		case "v":
			if len(parts) >= 4 {
				append(&obj.attrib.vertices, parse_float(parts[1]))
				append(&obj.attrib.vertices, parse_float(parts[2]))
				append(&obj.attrib.vertices, parse_float(parts[3]))
				v_count += 1
			}
		case "vn":
			if len(parts) >= 4 {
				append(&obj.attrib.normals, parse_float(parts[1]))
				append(&obj.attrib.normals, parse_float(parts[2]))
				append(&obj.attrib.normals, parse_float(parts[3]))
				vn_count += 1
			}
		case "vt":
			if len(parts) >= 3 {
				append(&obj.attrib.texcoords, parse_float(parts[1]))
				append(&obj.attrib.texcoords, parse_float(parts[2]))
				vt_count += 1
			}
		case "f":
			face_indices := make([dynamic]Vertex_Index, 0, 4)
			defer delete(face_indices)

			for i := 1; i < len(parts); i += 1 {
				vi := Vertex_Index{INVALID_INDEX, INVALID_INDEX, INVALID_INDEX}

				slashes := strings.split(parts[i], "/")
				defer delete(slashes)

				if len(slashes) >= 1 && len(slashes[0]) > 0 {
					vi.v_idx = fix_index(parse_int(slashes[0]), v_count)
				}
				if len(slashes) >= 2 && len(slashes[1]) > 0 {
					vi.vt_idx = fix_index(parse_int(slashes[1]), vt_count)
				}
				if len(slashes) >= 3 && len(slashes[2]) > 0 {
					vi.vn_idx = fix_index(parse_int(slashes[2]), vn_count)
				}
				append(&face_indices, vi)
			}

			if triangulate && len(face_indices) > 3 {
				i0 := face_indices[0]
				for k := 2; k < len(face_indices); k += 1 {
					append(&obj.attrib.faces, i0)
					append(&obj.attrib.faces, face_indices[k - 1])
					append(&obj.attrib.faces, face_indices[k])
					face_count += 3
				}
			} else {
				for vi in face_indices {
					append(&obj.attrib.faces, vi)
				}
				face_count += len(face_indices)
			}

		case "o", "g":
			if len(parts) >= 2 {
				if face_count > prev_shape_face_offset {
					commit_shape(
						&obj,
						current_shape_name,
						prev_shape_face_offset,
						face_count - prev_shape_face_offset,
						allocator,
					)
					prev_shape_face_offset = face_count
				}
				current_shape_name = parts[1]
			}
		}
	}

	if face_count > prev_shape_face_offset {
		commit_shape(&obj, current_shape_name, prev_shape_face_offset, face_count - prev_shape_face_offset, allocator)
	}

	return obj, true
}

destroy :: proc(obj: ^OBJ) {
	delete(obj.attrib.vertices)
	delete(obj.attrib.normals)
	delete(obj.attrib.texcoords)
	delete(obj.attrib.faces)
	for s in obj.shapes do delete(s.name)
	delete(obj.shapes)
}


package graphics

import "core:log"
import "core:strings"

import cgltf "vendor:cgltf"

load_model_gltf :: proc(engine: ^Engine, path: string, material: MaterialHandle) -> ModelHandle {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)

	options := cgltf.options{}
	gltf_data, res := cgltf.parse_file(options, c_path)
	if res != .success {
		log.errorf("cgltf: failed to parse {}: {}", path, res)
		return INVALID_MODEL
	}
	defer cgltf.free(gltf_data)

	res = cgltf.load_buffers(options, gltf_data, c_path)
	if res != .success {
		log.errorf("cgltf: failed to load buffers for {}: {}", path, res)
		return INVALID_MODEL
	}

	first_handle := INVALID_MODEL

	for &mesh in gltf_data.meshes {
		for &prim in mesh.primitives {
			if prim.type != .triangles {
				continue
			}

			pos_acc, uv_acc, norm_acc, tan_acc: ^cgltf.accessor
			for attr in prim.attributes {
				switch attr.type {
				case .position:  pos_acc  = attr.data
				case .texcoord:  uv_acc   = attr.data
				case .normal:    norm_acc = attr.data
				case .tangent:   tan_acc  = attr.data
				case .invalid, .color, .joints, .weights, .custom:
				}
			}

			if pos_acc == nil {
				log.warnf("cgltf: primitive in {} has no POSITION, skipping", path)
				continue
			}

			vertex_count := uint(pos_acc.count)
			vertices := make([dynamic]Vertex, vertex_count, context.temp_allocator)

			for i in 0 ..< vertex_count {
				pos: [3]f32
				_ = cgltf.accessor_read_float(pos_acc, i, raw_data(pos[:]), 3)
				vertices[i].pos   = pos
				vertices[i].color = {1, 1, 1}
			}

			if uv_acc != nil {
				for i in 0 ..< vertex_count {
					uv: [2]f32
					_ = cgltf.accessor_read_float(uv_acc, i, raw_data(uv[:]), 2)
					vertices[i].uv = {uv[0], 1.0 - uv[1]}
				}
			}

			if norm_acc != nil {
				for i in 0 ..< vertex_count {
					n: [3]f32
					_ = cgltf.accessor_read_float(norm_acc, i, raw_data(n[:]), 3)
					vertices[i].normal = n
				}
			}

			if tan_acc != nil {
				for i in 0 ..< vertex_count {
					t: [4]f32
					_ = cgltf.accessor_read_float(tan_acc, i, raw_data(t[:]), 4)
					vertices[i].tangent = t
				}
			}

			indices := make([dynamic]u32, prim.indices.count, context.temp_allocator)
			for i in 0 ..< prim.indices.count {
				indices[i] = u32(cgltf.accessor_read_index(prim.indices, i))
			}

			prim_name := strings.join({path, string(mesh.name)}, ":", context.temp_allocator)
			handle := register_model(engine, prim_name, vertices[:], indices[:], material)
			if first_handle == INVALID_MODEL {
				first_handle = handle
			}
		}
	}

	return first_handle
}

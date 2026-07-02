package graphics

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"

import cgltf "vendor:cgltf"
import vk "vendor:vulkan"

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

	model := Model {
		name = path,
	}

	bounds_min := Vec3{max(f32), max(f32), max(f32)}
	bounds_max := Vec3{min(f32), min(f32), min(f32)}

	for &mesh in gltf_data.meshes {
		for &prim in mesh.primitives {
			if prim.type != .triangles {
				continue
			}

			pos_acc, uv_acc, norm_acc, tan_acc: ^cgltf.accessor
			for attr in prim.attributes {
				switch attr.type {
				case .position:
					pos_acc = attr.data
				case .texcoord:
					uv_acc = attr.data
				case .normal:
					norm_acc = attr.data
				case .tangent:
					tan_acc = attr.data
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
				vertices[i].pos = pos

				bounds_min = linalg.min(bounds_min, pos)
				bounds_max = linalg.max(bounds_max, pos)

				if uv_acc != nil {
					uv: [2]f32
					_ = cgltf.accessor_read_float(uv_acc, i, raw_data(uv[:]), 2)
					vertices[i].uv = uv
				}

				if norm_acc != nil {
					n: [3]f32
					_ = cgltf.accessor_read_float(norm_acc, i, raw_data(n[:]), 3)
					vertices[i].normal = n
				}

				if tan_acc != nil {
					t: [4]f32
					_ = cgltf.accessor_read_float(tan_acc, i, raw_data(t[:]), 4)
					vertices[i].tangent = t
				}
			}

			indices := make([dynamic]u32, prim.indices.count, context.temp_allocator)
			for i in 0 ..< prim.indices.count {
				indices[i] = u32(cgltf.accessor_read_index(prim.indices, i))
			}

			prim_mat: MaterialHandle
			if material != INVALID_MATERIAL {
				prim_mat = material
			} else if prim.material != nil {
				prim_mat = gltf_extract_material(engine, path, gltf_data, prim.material)
			} else {
				prim_mat = get_default_material(engine)
			}

			vertex_buf := buffer_upload(
				&engine.vk_ctx,
				raw_data(vertices[:]),
				vk.DeviceSize(size_of(Vertex) * len(vertices)),
				.Storage,
			)
			index_buf := buffer_upload(
				&engine.vk_ctx,
				raw_data(indices[:]),
				vk.DeviceSize(size_of(u32) * len(indices)),
				.Index,
			)

			append(
				&model.meshes,
				Mesh {
					vertex_buffer = vertex_buf.buffer,
					vertex_allocation = vertex_buf.alloc,
					vertex_address = vertex_buf.ptr,
					index_buffer = index_buf.buffer,
					index_allocation = index_buf.alloc,
					index_count = u32(len(indices)),
					material = prim_mat,
				},
			)
		}
	}

	if len(model.meshes) == 0 {
		log.warnf("cgltf: no meshes found in {}", path)
		return INVALID_MODEL
	}

	center := (bounds_min + bounds_max) * 0.5
	model.bounds = BoundingSphere{center, linalg.length(bounds_max - center)}

	handle := pool_alloc(&engine.model_system.models, model)
	engine.model_system.model_map[path] = handle
	return handle
}

gltf_extract_material :: proc(
	engine: ^Engine,
	model_path: string,
	data: ^cgltf.data,
	mat: ^cgltf.material,
) -> MaterialHandle {
	mat_idx := cgltf.material_index(data, mat)
	name := string(mat.name) if mat.name != nil && mat.name != "" else fmt.tprintf("{}:mat_{}", model_path, mat_idx)

	if handle, ok := engine.material_system.material_map[name]; ok {
		return handle
	}

	load_tex :: proc(
		engine: ^Engine,
		model_path: string,
		data: ^cgltf.data,
		tv: ^cgltf.texture_view,
		is_srgb: bool,
	) -> TextureHandle {
		if tv.texture == nil || tv.texture.image_ == nil {
			return INVALID_TEXTURE
		}
		img := tv.texture.image_
		img_idx := cgltf.image_index(data, img)
		tex_name := fmt.tprintf("{}:img_{}", model_path, img_idx)

		if img.buffer_view != nil {
			bv := img.buffer_view
			raw := cgltf.buffer_view_data(bv)
			return texture_load_from_memory(engine, tex_name, raw[:bv.size], is_srgb)
		}

		if img.uri != nil {
			dir := filepath.dir(model_path)
			full_path, _ := filepath.join({dir, string(img.uri)}, context.temp_allocator)
			return texture_load_from_file(engine, full_path, is_srgb)
		}

		return INVALID_TEXTURE
	}

	pbr := &mat.pbr_metallic_roughness
	base_color_tex := load_tex(engine, model_path, data, &pbr.base_color_texture, true)
	mr_tex := load_tex(engine, model_path, data, &pbr.metallic_roughness_texture, false)
	normal_tex := load_tex(engine, model_path, data, &mat.normal_texture, false)
	occlusion_tex := load_tex(engine, model_path, data, &mat.occlusion_texture, false)

	base_color := Vec4 {
		pbr.base_color_factor[0],
		pbr.base_color_factor[1],
		pbr.base_color_factor[2],
		pbr.base_color_factor[3],
	}

	return create_material(
		engine,
		name,
		base_color = base_color,
		perceptual_roughness = pbr.roughness_factor,
		metallic = pbr.metallic_factor,
		base_color_texture = base_color_tex,
		metallic_roughness_texture = mr_tex,
		normal_map_texture = normal_tex,
		occlusion_texture = occlusion_tex,
	)
}

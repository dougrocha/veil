package graphics

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"

import "backend"

import cgltf "vendor:cgltf"

@(private = "file")
gltf_open :: proc(path: string) -> (^cgltf.data, bool) {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)

	options := cgltf.options{}
	gltf_data, res := cgltf.parse_file(options, c_path)
	if res != .success {
		log.errorf("cgltf: failed to parse {}: {}", path, res)
		return nil, false
	}

	res = cgltf.load_buffers(options, gltf_data, c_path)
	if res != .success {
		log.errorf("cgltf: failed to load buffers for {}: {}", path, res)
		cgltf.free(gltf_data)
		return nil, false
	}
	return gltf_data, true
}

// Mesh nodes of the default scene, depth first. Files without scenes use every root node.
@(private = "file")
gltf_mesh_nodes :: proc(data: ^cgltf.data) -> []^cgltf.node {
	nodes := make([dynamic]^cgltf.node, context.temp_allocator)

	visit :: proc(nodes: ^[dynamic]^cgltf.node, node: ^cgltf.node) {
		if node.mesh != nil do append(nodes, node)
		for child in node.children do visit(nodes, child)
	}

	scene := data.scene
	if scene == nil && len(data.scenes) > 0 do scene = &data.scenes[0]
	if scene != nil {
		for root in scene.nodes do visit(&nodes, root)
	} else {
		for &node in data.nodes {
			if node.parent == nil do visit(&nodes, &node)
		}
	}
	return nodes[:]
}

@(private = "file")
gltf_node_world :: proc(node: ^cgltf.node) -> Mat4x4 {
	m: [16]f32
	cgltf.node_transform_world(node, raw_data(m[:]))
	return transmute(Mat4x4)m // both column major
}

// Loads every mesh node of the default scene into one Model, with node transforms baked into the
// vertices. Use model_load_parts to keep nodes as separate instances.
model_load_gltf :: proc(engine: ^Engine, path: string, material: MaterialHandle) -> ModelHandle {
	gltf_data, ok := gltf_open(path)
	if !ok do return INVALID_MODEL
	defer cgltf.free(gltf_data)

	model := Model {
		name = strings.clone(path),
	}
	for node in gltf_mesh_nodes(gltf_data) {
		world := gltf_node_world(node)
		for &prim in node.mesh.primitives {
			if mesh, _, prim_ok := gltf_load_primitive(engine, path, gltf_data, &prim, material, world); prim_ok {
				append(&model.meshes, mesh)
			}
		}
	}

	if len(model.meshes) == 0 {
		log.warnf("cgltf: no meshes found in {}", path)
		delete(model.meshes)
		delete(model.name)
		return INVALID_MODEL
	}
	return model_add(engine, model)
}

// One part per mesh node, or per primitive of each mesh node with split_primitives. Nodes that
// share a glTF mesh share its models.
model_load_gltf_parts :: proc(
	engine: ^Engine,
	path: string,
	material: MaterialHandle,
	split_primitives: bool,
) -> []ModelPart {
	gltf_data, ok := gltf_open(path)
	if !ok do return nil
	defer cgltf.free(gltf_data)

	// Per glTF mesh: its models, each placed relative to the node that references it.
	mesh_pieces := make([][]ModelPart, len(gltf_data.meshes), context.temp_allocator)
	mesh_loaded := make([]bool, len(gltf_data.meshes), context.temp_allocator)

	parts := make([dynamic]ModelPart)
	for node in gltf_mesh_nodes(gltf_data) {
		mesh_index := cgltf.mesh_index(gltf_data, node.mesh)
		if !mesh_loaded[mesh_index] {
			mesh_pieces[mesh_index] = gltf_load_mesh_pieces(
				engine,
				path,
				gltf_data,
				int(mesh_index),
				material,
				split_primitives,
			)
			mesh_loaded[mesh_index] = true
		}

		world := gltf_node_world(node)
		for piece in mesh_pieces[mesh_index] {
			append(
				&parts,
				ModelPart {
					model = piece.model,
					transform = transform_from_matrix(world * transform_to_matrix(piece.transform)),
				},
			)
		}
	}

	if len(parts) == 0 do log.warnf("cgltf: no meshes found in {}", path)
	return parts[:]
}

// Registers one Model for the whole glTF mesh, or one per primitive recentered on its own bounds
// so a split piece pivots around itself instead of the file origin.
@(private = "file")
gltf_load_mesh_pieces :: proc(
	engine: ^Engine,
	path: string,
	data: ^cgltf.data,
	mesh_index: int,
	material: MaterialHandle,
	split_primitives: bool,
) -> []ModelPart {
	gltf_mesh := &data.meshes[mesh_index]
	pieces := make([dynamic]ModelPart, context.temp_allocator)

	if split_primitives {
		for &prim, prim_index in gltf_mesh.primitives {
			mesh, center, ok := gltf_load_primitive(engine, path, data, &prim, material, recenter = true)
			if !ok do continue
			model := Model {
				name = fmt.aprintf("{}#mesh{}.prim{}", path, mesh_index, prim_index),
			}
			append(&model.meshes, mesh)
			append(&pieces, ModelPart{model_add(engine, model), transform_create(translation = center)})
		}
		return pieces[:]
	}

	model := Model {
		name = fmt.aprintf("{}#mesh{}", path, mesh_index),
	}
	for &prim in gltf_mesh.primitives {
		if mesh, _, ok := gltf_load_primitive(engine, path, data, &prim, material); ok {
			append(&model.meshes, mesh)
		}
	}
	if len(model.meshes) == 0 {
		delete(model.meshes)
		delete(model.name)
		return nil
	}
	append(&pieces, ModelPart{model_add(engine, model), transform_create()})
	return pieces[:]
}

// Uploads one triangle primitive with xform baked into its vertices. With recenter, positions are
// shifted so the mesh bounds are centered on the origin, and the removed offset is returned.
@(private = "file")
gltf_load_primitive :: proc(
	engine: ^Engine,
	path: string,
	data: ^cgltf.data,
	prim: ^cgltf.primitive,
	material: MaterialHandle,
	xform := linalg.MATRIX4F32_IDENTITY,
	recenter := false,
) -> (
	mesh: Mesh,
	center: Vec3,
	ok: bool,
) {
	if prim.type != .triangles do return
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
		return
	}

	linear := linalg.matrix3_from_matrix4(xform)
	normal_matrix := linalg.transpose(linalg.inverse(linear))
	// A mirroring transform flips triangle winding and tangent-space handedness.
	mirrored := linalg.determinant(linear) < 0

	vertex_count := uint(pos_acc.count)
	vertices := make([]MeshVertex, vertex_count, context.temp_allocator)
	positions := make([]Vec3, vertex_count)

	for i in 0 ..< vertex_count {
		pos: [3]f32
		_ = cgltf.accessor_read_float(pos_acc, i, raw_data(pos[:]), 3)
		positions[i] = (xform * Vec4{pos.x, pos.y, pos.z, 1}).xyz

		if uv_acc != nil {
			uv: [2]f32
			_ = cgltf.accessor_read_float(uv_acc, i, raw_data(uv[:]), 2)
			vertices[i].uv = uv
		}

		if norm_acc != nil {
			n: [3]f32
			_ = cgltf.accessor_read_float(norm_acc, i, raw_data(n[:]), 3)
			vertices[i].normal = linalg.normalize0(normal_matrix * Vec3(n))
		}

		if tan_acc != nil {
			t: [4]f32
			_ = cgltf.accessor_read_float(tan_acc, i, raw_data(t[:]), 4)
			tangent := linalg.normalize0(linear * t.xyz)
			vertices[i].tangent = {tangent.x, tangent.y, tangent.z, -t.w if mirrored else t.w}
		}
	}

	bounds := aabb_from_points(positions)
	if recenter {
		center = bounds.center
		bounds.center = {}
		for &p in positions do p -= center
	}
	for p, i in positions do vertices[i].pos = p

	// Non-indexed primitives draw their vertices in order.
	indices: []u32
	if prim.indices != nil {
		indices = make([]u32, prim.indices.count)
		for i in 0 ..< prim.indices.count do indices[i] = u32(cgltf.accessor_read_index(prim.indices, i))
	} else {
		indices = make([]u32, vertex_count)
		for i in 0 ..< vertex_count do indices[i] = u32(i)
	}
	if mirrored {
		for i := 0; i + 2 < len(indices); i += 3 do indices[i + 1], indices[i + 2] = indices[i + 2], indices[i + 1]
	}

	prim_mat: MaterialHandle
	if material != INVALID_MATERIAL {
		prim_mat = material
	} else if prim.material != nil {
		prim_mat = gltf_extract_material(engine, path, data, prim.material)
	} else {
		prim_mat = material_get_default(engine)
	}

	mesh = Mesh {
		vertex_buffer = vertex_buffer_upload(engine, vertices),
		index_buffer  = backend.buffer_upload(&engine.vk_ctx, indices, {.Index}),
		index_count   = u32(len(indices)),
		material      = prim_mat,
		positions     = positions,
		indices       = indices,
		bounds        = bounds,
	}
	return mesh, center, true
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
	// HDR emission = emissiveFactor * KHR_materials_emissive_strength. Emissive textures aren't
	// supported yet, and in glTF the factor multiplies the texture (usually a factor of 1 with the
	// pattern in the texture), so a textured material would glow uniformly. Skip those instead.
	emissive: Vec3
	if mat.emissive_texture.texture != nil {
		log.warnf("Material \"%s\": emissive textures are not supported; ignoring emission", name)
	} else {
		strength := mat.emissive_strength.emissive_strength if mat.has_emissive_strength else 1
		emissive = Vec3{mat.emissive_factor[0], mat.emissive_factor[1], mat.emissive_factor[2]} * strength
	}
	alpha_mode: AlphaMode
	switch mat.alpha_mode {
	case .opaque:
		alpha_mode = .Opaque
	case .mask:
		alpha_mode = .Mask
	case .blend:
		alpha_mode = .Blend
	}

	return material_create(
		engine,
		name,
		base_color = base_color,
		perceptual_roughness = pbr.roughness_factor,
		metallic = pbr.metallic_factor,
		base_color_texture = base_color_tex,
		metallic_roughness_texture = mr_tex,
		normal_map_texture = normal_tex,
		occlusion_texture = occlusion_tex,
		alpha_mode = alpha_mode,
		alpha_cutoff = mat.alpha_cutoff,
		emissive = emissive,
		double_sided = bool(mat.double_sided),
	)
}

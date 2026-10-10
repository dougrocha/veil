package graphics

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"

import "shared:tinyobj"

import "backend"

// Packed with no padding: uv rides in the w of position and normal. CPU code builds MeshVertex and
// model_register packs it.
@(shader_shared)
Vertex :: struct #max_field_align(16) {
	pos_uv_x:    Vec4, // xyz position, w uv.x
	normal_uv_y: Vec4, // xyz normal, w uv.y
	tangent:     Vec4, // xyz tangent, w bitangent sign
}

@(shader_shared)
MeshPushConstants :: struct #max_field_align(16) {
	scene_data:       backend.GPUPtr(SceneData),
	vertex_buffer:    backend.GPUPtr(Vertex),
	material_buffer:  backend.GPUPtr(GpuMaterial),
	transform_buffer: backend.GPUPtr(GpuTransform),
	instance_ids:     backend.GPUPtr(u32), // see instancing.odin
}

Mesh :: struct {
	sort_key:     u64, // stable registration order, including shared-geometry material variants
	first_vertex: i32,
	first_index:  u32,
	index_count:  u32,
	material:     MaterialHandle,
	positions:    []Vec3,
	indices:      []u32,
	bounds:       AABB, // model space
}

ModelHandle :: Handle(Model)

INVALID_MODEL :: ModelHandle{}

Model :: struct {
	borrowed_geometry: bool, // shared-buffer ranges and CPU geometry belong to another engine-owned model
	variant_of:        Handle(Model), // root asset of a model_with_material variant; INVALID_MODEL for assets
	meshes:            [dynamic]Mesh,
	name:              string,
	bounds:            BoundingSphere,
}

// One spawnable piece of a file loaded with model_load_parts. transform places the piece
// relative to the file's root.
ModelPart :: struct {
	model:     ModelHandle,
	transform: Transform,
}

// Cache key for model_with_material: one variant per root asset and material.
ModelVariantKey :: struct {
	source:   ModelHandle,
	material: MaterialHandle,
}

ModelSystem :: struct {
	next_mesh_key: u64,
	vertex_buffer: backend.Buffer(Vertex),
	index_buffer:  backend.Buffer(u32),
	next_vertex:   int,
	next_index:    int,
	models:        Pool(Model),
	model_map:     map[string]ModelHandle, // asset identity: model_load path, or a registered name
	variant_map:   map[ModelVariantKey]ModelHandle,
	primitive_map: map[PrimitiveKey]ModelHandle, // base shapes by parameters, see primitives.odin
	parts_map:     map[string][]ModelPart,
}

// Fixed capacity for the largest scene plus its primitive and material-variant geometry. Ranges
// are bump-allocated and remain reserved until shutdown; models have no runtime unload operation.
MODEL_VERTEX_CAPACITY :: 1 * 1024 * 1024
MODEL_INDEX_CAPACITY :: 4 * 1024 * 1024

model_system_create :: proc(engine: ^Engine) {
	engine.model_system.vertex_buffer = backend.buffer_create(
		Vertex,
		&engine.vk_ctx,
		MODEL_VERTEX_CAPACITY,
		{.Storage, .Transfer_Dst},
		.Gpu,
	)
	engine.model_system.index_buffer = backend.buffer_create(
		u32,
		&engine.vk_ctx,
		MODEL_INDEX_CAPACITY,
		{.Index, .Transfer_Dst},
		.Gpu,
	)
	engine.model_system.models = pool_init(16384, Model)
	engine.model_system.model_map = make(map[string]ModelHandle)
	engine.model_system.variant_map = make(map[ModelVariantKey]ModelHandle)
	engine.model_system.primitive_map = make(map[PrimitiveKey]ModelHandle)
	engine.model_system.parts_map = make(map[string][]ModelPart)
}

model_system_destroy :: proc(engine: ^Engine) {
	ms := &engine.model_system
	for &model, i in ms.models.values {
		if pool_is_alive(&ms.models, Index(i)) {
			for &mesh in model.meshes {
				if model.borrowed_geometry do continue
				delete(mesh.positions)
				delete(mesh.indices)
			}
			delete(model.meshes)
			delete(model.name)
		}
	}
	backend.buffer_destroy(&engine.vk_ctx, ms.vertex_buffer)
	backend.buffer_destroy(&engine.vk_ctx, ms.index_buffer)
	pool_destroy(&ms.models)
	delete(ms.model_map)
	delete(ms.variant_map)
	delete(ms.primitive_map)
	for key, parts in ms.parts_map {
		delete(key)
		delete(parts)
	}
	delete(ms.parts_map)
}

// Loads a model by asset path, cached by path. Materials come from the file or the default; use
// model_with_material to bind a different one.
model_load :: proc(engine: ^Engine, path: string) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[path]; ok {
		return handle
	}

	ext := filepath.ext(path)
	if ext == ".gltf" || ext == ".glb" {
		return model_load_gltf(engine, path)
	}

	obj, ok := tinyobj.load_from_file_path(path, allocator = context.temp_allocator)
	if !ok {
		log.errorf("Failed to read model from {}", path)
		return INVALID_MODEL
	}

	vertices := make([dynamic]MeshVertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	unique_vertices := make(map[MeshVertex]u32, context.temp_allocator)

	for shape in obj.shapes {
		for index in obj.attrib.faces[shape.face_offset:shape.face_offset + shape.length] {
			normal: Vec3 = {0.0, 1.0, 0.0}
			if index.vn_idx != tinyobj.INVALID_INDEX {
				normal = {
					obj.attrib.normals[3 * index.vn_idx + 0],
					obj.attrib.normals[3 * index.vn_idx + 1],
					obj.attrib.normals[3 * index.vn_idx + 2],
				}
			}

			uv: Vec2
			if index.vt_idx != tinyobj.INVALID_INDEX {
				uv = {obj.attrib.texcoords[2 * index.vt_idx + 0], 1.0 - obj.attrib.texcoords[2 * index.vt_idx + 1]}
			}

			vertex := MeshVertex {
				pos    = {
					obj.attrib.vertices[3 * index.v_idx + 0],
					obj.attrib.vertices[3 * index.v_idx + 1],
					obj.attrib.vertices[3 * index.v_idx + 2],
				},
				uv     = uv,
				normal = normal,
			}

			_, val, inserted, _ := map_entry(&unique_vertices, vertex)
			if inserted {
				val^ = u32(len(vertices))
				append(&vertices, vertex)
			}
			append(&indices, val^)
		}
	}

	return model_register(engine, path, vertices[:], indices[:])
}

// A vertex as loaders and primitives build it. mesh_geometry_upload packs it into the GPU Vertex.
MeshVertex :: struct {
	pos:     Vec3,
	uv:      Vec2,
	normal:  Vec3,
	tangent: Vec4, // xyz tangent, w bitangent sign
}

// Packs one mesh into shared buffers. Indices remain local to the mesh; draws provide the base vertex.
mesh_geometry_upload :: proc(
	engine: ^Engine,
	vertices: []MeshVertex,
	indices: []u32,
) -> (
	first_vertex: i32,
	first_index: u32,
) {
	ms := &engine.model_system
	fmt.assertf(
		ms.next_vertex + len(vertices) <= MODEL_VERTEX_CAPACITY,
		"model vertex buffer capacity exceeded: need %d of %d vertices",
		ms.next_vertex + len(vertices),
		MODEL_VERTEX_CAPACITY,
	)
	fmt.assertf(
		ms.next_index + len(indices) <= MODEL_INDEX_CAPACITY,
		"model index buffer capacity exceeded: need %d of %d indices",
		ms.next_index + len(indices),
		MODEL_INDEX_CAPACITY,
	)
	packed := make([]Vertex, len(vertices), context.temp_allocator)
	for v, i in vertices {
		packed[i] = {
			pos_uv_x    = {v.pos.x, v.pos.y, v.pos.z, v.uv.x},
			normal_uv_y = {v.normal.x, v.normal.y, v.normal.z, v.uv.y},
			tangent     = v.tangent,
		}
	}
	first_vertex = i32(ms.next_vertex)
	first_index = u32(ms.next_index)
	backend.buffer_upload_range(&engine.vk_ctx, ms.vertex_buffer, packed, ms.next_vertex)
	backend.buffer_upload_range(&engine.vk_ctx, ms.index_buffer, indices, ms.next_index)
	ms.next_vertex += len(vertices)
	ms.next_index += len(indices)
	return
}

model_register :: proc(
	engine: ^Engine,
	name: string,
	vertices: []MeshVertex,
	indices: []u32,
	material: MaterialHandle = INVALID_MATERIAL,
) -> ModelHandle {
	return model_add(engine, model_make(engine, name, vertices, indices, material))
}

// Uploads one mesh and returns it as an unregistered model, named by a copy of name. Callers add it
// with model_add (indexed by name) or model_pool_add (not indexed).
model_make :: proc(
	engine: ^Engine,
	name: string,
	vertices: []MeshVertex,
	indices: []u32,
	material: MaterialHandle = INVALID_MATERIAL,
) -> Model {
	first_vertex, first_index := mesh_geometry_upload(engine, vertices, indices)

	material_handle := material_get_default(engine) if material == INVALID_MATERIAL else material
	positions := make([]Vec3, len(vertices))
	for v, i in vertices {
		positions[i] = v.pos
	}
	mesh_indices := make([]u32, len(indices))
	copy(mesh_indices, indices)

	mesh := Mesh {
		first_vertex = first_vertex,
		first_index  = first_index,
		index_count  = u32(len(indices)),
		material     = material_handle,
		positions    = positions,
		indices      = mesh_indices,
		bounds       = aabb_from_points(positions),
	}

	model := Model {
		name = strings.clone(name),
	}
	append(&model.meshes, mesh)
	return model
}

// Takes ownership of model, whose name must be an owned copy (it doubles as the map key).
model_add :: proc(engine: ^Engine, model: Model) -> ModelHandle {
	handle := model_pool_add(engine, model)
	engine.model_system.model_map[model.name] = handle
	return handle
}

// Assigns sort keys and bounds and allocates the model, without indexing it by name. Takes ownership
// of model. Variants use this so their names never shadow an asset path.
model_pool_add :: proc(engine: ^Engine, model: Model) -> ModelHandle {
	model := model
	for &mesh in model.meshes {
		engine.model_system.next_mesh_key += 1
		mesh.sort_key = engine.model_system.next_mesh_key
	}
	model_compute_bounds(&model)
	return pool_alloc(&engine.model_system.models, model)
}

// Bounding sphere around every mesh, centered on the union of their AABBs.
model_compute_bounds :: proc(model: ^Model) {
	if len(model.meshes) == 0 do return
	lo := model.meshes[0].bounds.center - model.meshes[0].bounds.extents
	hi := model.meshes[0].bounds.center + model.meshes[0].bounds.extents
	for &mesh in model.meshes[1:] {
		lo = linalg.min(lo, mesh.bounds.center - mesh.bounds.extents)
		hi = linalg.max(hi, mesh.bounds.center + mesh.bounds.extents)
	}
	center := (lo + hi) * 0.5
	radius: f32 = 0
	for &mesh in model.meshes {
		for p in mesh.positions {
			radius = max(radius, linalg.length(p - center))
		}
	}
	model.bounds = BoundingSphere{center, radius}
}

// Loads a file as separately spawnable pieces. glTF files get one part per mesh node, or one per
// primitive of each mesh node with split_primitives (for files flattened into a single mesh, like
// Sponza). Other formats come back as a single part. A part bound to another material comes from
// model_with_material on that part's model.
model_load_parts :: proc(engine: ^Engine, path: string, split_primitives := false) -> []ModelPart {
	key := fmt.tprintf("{}#split", path) if split_primitives else path
	if parts, ok := engine.model_system.parts_map[key]; ok {
		return parts
	}

	parts: []ModelPart
	ext := filepath.ext(path)
	if ext == ".gltf" || ext == ".glb" {
		parts = model_load_gltf_parts(engine, path, split_primitives)
	} else {
		model := model_load(engine, path)
		if model != INVALID_MODEL {
			parts = make([]ModelPart, 1)
			parts[0] = {
				model     = model,
				transform = transform_create(),
			}
		}
	}
	if len(parts) > 0 {
		engine.model_system.parts_map[strings.clone(key)] = parts
	}
	return parts
}

// Binds source's geometry to another material. The variant borrows the source's shared ranges and CPU
// geometry, and is cached per (root asset, material), so repeated calls return the same handle. A
// variant of a variant resolves to its root asset first. Both models live until engine_destroy.
model_with_material :: proc(engine: ^Engine, source: ModelHandle, material: MaterialHandle) -> ModelHandle {
	ms := &engine.model_system
	if !pool_is_valid(&ms.models, source) {
		log.errorf("model_with_material: source model is invalid (failed load?)")
		return INVALID_MODEL
	}
	assert(pool_is_valid(&engine.material_system.materials, material))

	root := source
	if variant_of := pool_get(&ms.models, source).variant_of; variant_of != INVALID_MODEL {
		root = variant_of
	}

	key := ModelVariantKey{root, material}
	if handle, ok := ms.variant_map[key]; ok do return handle

	original := pool_get(&ms.models, root)
	variant := Model {
		name              = fmt.aprintf(
			"{}+{}",
			original.name,
			pool_get(&engine.material_system.materials, material).name,
		),
		borrowed_geometry = true,
		variant_of        = root,
	}
	for mesh in original.meshes {
		mesh := mesh
		mesh.material = material
		append(&variant.meshes, mesh)
	}
	handle := model_pool_add(engine, variant)
	ms.variant_map[key] = handle
	return handle
}

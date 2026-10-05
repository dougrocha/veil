package graphics

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"

import "shared:tinyobj"

import "backend"

Mesh :: struct {
	vertex_buffer: backend.Buffer(Vertex),
	index_buffer:  backend.Buffer(u32),
	index_count:   u32,
	material:      MaterialHandle,
	positions:     []Vec3,
	indices:       []u32,
	bounds:        AABB, // model space
}

ModelHandle :: Handle(Model)

INVALID_MODEL :: ModelHandle{}

InstanceHandle :: Handle(Instance)

INVALID_INSTANCE :: InstanceHandle{}

Model :: struct {
	meshes: [dynamic]Mesh,
	name:   string,
	bounds: BoundingSphere,
}

Instance :: struct {
	model:        ModelHandle,
	transform:    Transform,
	casts_shadow: bool,
}

MAX_MODEL_INSTANCES :: 4096

// One setter or spawn call on an instance. Bounds are world-space spheres; a spawn has no old bounds.
InstanceChange :: struct {
	instance:         InstanceHandle,
	old_bounds:       Maybe(BoundingSphere),
	new_bounds:       BoundingSphere,
	casts_shadow_old: bool,
	casts_shadow_new: bool,
}

// One spawnable piece of a file loaded with model_load_parts. transform places the piece
// relative to the file's root.
ModelPart :: struct {
	model:     ModelHandle,
	transform: Transform,
}

ModelSystem :: struct {
	models:    Pool(Model),
	model_map: map[string]ModelHandle,
	parts_map: map[string][]ModelPart,
}

model_system_create :: proc(engine: ^Engine) {
	engine.model_system.models = pool_init(1024, Model)
	engine.model_system.model_map = make(map[string]ModelHandle)
	engine.model_system.parts_map = make(map[string][]ModelPart)
	engine.scene.instances = pool_init(MAX_MODEL_INSTANCES, Instance)
}

model_system_destroy :: proc(engine: ^Engine) {
	ms := &engine.model_system
	for &model, i in ms.models.values {
		if pool_is_alive(&ms.models, Index(i)) {
			for &mesh in model.meshes {
				backend.buffer_destroy(&engine.vk_ctx, mesh.vertex_buffer)
				backend.buffer_destroy(&engine.vk_ctx, mesh.index_buffer)
				delete(mesh.positions)
				delete(mesh.indices)
			}
			delete(model.meshes)
			delete(model.name)
		}
	}
	pool_destroy(&ms.models)
	delete(ms.model_map)
	for key, parts in ms.parts_map {
		delete(key)
		delete(parts)
	}
	delete(ms.parts_map)
	pool_destroy(&engine.scene.instances)
	delete(engine.scene.instance_changes)
}

model_load :: proc(engine: ^Engine, path: string, material: MaterialHandle = INVALID_MATERIAL) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[path]; ok {
		return handle
	}

	ext := filepath.ext(path)
	if ext == ".gltf" || ext == ".glb" {
		return model_load_gltf(engine, path, material)
	}

	obj, ok := tinyobj.load_from_file_path(path, allocator = context.temp_allocator)
	if !ok {
		log.errorf("Failed to read model from {}", path)
		return INVALID_MODEL
	}

	vertices := make([dynamic]Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	unique_vertices := make(map[Vertex]u32, context.temp_allocator)

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

			vertex := Vertex {
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

	return model_register(engine, path, vertices[:], indices[:], material)
}

model_register :: proc(
	engine: ^Engine,
	name: string,
	vertices: []Vertex,
	indices: []u32,
	material: MaterialHandle = INVALID_MATERIAL,
) -> ModelHandle {
	vertex_buf := backend.buffer_upload(&engine.vk_ctx, vertices, {.Storage})
	index_buf := backend.buffer_upload(&engine.vk_ctx, indices, {.Index})

	material_handle := material_get_default(engine) if material == INVALID_MATERIAL else material
	positions := make([]Vec3, len(vertices))
	for v, i in vertices {
		positions[i] = v.pos
	}
	mesh_indices := make([]u32, len(indices))
	copy(mesh_indices, indices)

	mesh := Mesh {
		vertex_buffer = vertex_buf,
		index_buffer  = index_buf,
		index_count   = u32(len(indices)),
		material      = material_handle,
		positions     = positions,
		indices       = mesh_indices,
		bounds        = aabb_from_points(positions),
	}

	model := Model {
		name = strings.clone(name),
	}
	append(&model.meshes, mesh)
	return model_add(engine, model)
}

// Takes ownership of model, whose name must be an owned copy (it doubles as the map key).
model_add :: proc(engine: ^Engine, model: Model) -> ModelHandle {
	model := model
	model_compute_bounds(&model)
	handle := pool_alloc(&engine.model_system.models, model)
	engine.model_system.model_map[model.name] = handle
	return handle
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
// Sponza). Other formats come back as a single part.
model_load_parts :: proc(
	engine: ^Engine,
	path: string,
	material: MaterialHandle = INVALID_MATERIAL,
	split_primitives := false,
) -> []ModelPart {
	key := fmt.tprintf("{}#split", path) if split_primitives else path
	if parts, ok := engine.model_system.parts_map[key]; ok {
		return parts
	}

	parts: []ModelPart
	ext := filepath.ext(path)
	if ext == ".gltf" || ext == ".glb" {
		parts = model_load_gltf_parts(engine, path, material, split_primitives)
	} else {
		model := model_load(engine, path, material)
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

// Spawns one instance per part, placed as if the parts were children of transform.
// Returns the handles in part order.
instance_spawn_parts :: proc(
	engine: ^Engine,
	parts: []ModelPart,
	transform: Transform,
	casts_shadow := true,
	allocator := context.temp_allocator,
) -> []InstanceHandle {
	handles := make([]InstanceHandle, len(parts), allocator)
	parent := transform_to_matrix(transform)
	for part, i in parts {
		part_transform := transform_from_matrix(parent * transform_to_matrix(part.transform))
		handles[i] = instance_spawn(engine, part.model, part_transform, casts_shadow)
	}
	return handles
}

// Returns a copy. Change an instance through the setters, so the change is recorded.
instance_get :: proc(engine: ^Engine, handle: InstanceHandle) -> Instance {
	return pool_get(&engine.scene.instances, handle)^
}

instance_set_transform :: proc(engine: ^Engine, handle: InstanceHandle, transform: Transform) {
	instance := pool_get(&engine.scene.instances, handle)
	old := instance^
	instance.transform = transform
	instance_change_record(engine, handle, old, instance^)
}

instance_set_casts_shadow :: proc(engine: ^Engine, handle: InstanceHandle, casts_shadow: bool) {
	instance := pool_get(&engine.scene.instances, handle)
	old := instance^
	instance.casts_shadow = casts_shadow
	instance_change_record(engine, handle, old, instance^)
}

// World-space bounding sphere: the model's sphere moved by the transform, radius scaled by the
// largest axis scale.
instance_world_sphere :: proc(engine: ^Engine, instance: Instance) -> BoundingSphere {
	model := pool_get(&engine.model_system.models, instance.model)
	center :=
		transform_to_matrix(instance.transform) *
		Vec4{model.bounds.center.x, model.bounds.center.y, model.bounds.center.z, 1}
	scale := transform_global_scale(instance.transform)
	max_scale := max(math.abs(scale.x), math.abs(scale.y), math.abs(scale.z))
	return BoundingSphere{center.xyz, model.bounds.radius * max_scale}
}

// Appends one change per call, never merged. old is nil for a spawn.
@(private = "file")
instance_change_record :: proc(engine: ^Engine, handle: InstanceHandle, old: Maybe(Instance), new: Instance) {
	change := InstanceChange {
		instance         = handle,
		new_bounds       = instance_world_sphere(engine, new),
		casts_shadow_new = new.casts_shadow,
	}
	if o, ok := old.?; ok {
		change.old_bounds = instance_world_sphere(engine, o)
		change.casts_shadow_old = o.casts_shadow
	}
	append(&engine.scene.instance_changes, change)
}

instance_spawn :: proc(
	engine: ^Engine,
	model: ModelHandle,
	transform: Transform,
	casts_shadow := true,
) -> InstanceHandle {
	if model == INVALID_MODEL {
		log.errorf("spawn: refusing to spawn an instance of an invalid model handle")
		return INVALID_INSTANCE
	}
	instance := Instance {
		model        = model,
		transform    = transform,
		casts_shadow = casts_shadow,
	}
	handle := pool_alloc(&engine.scene.instances, instance)
	instance_change_record(engine, handle, nil, instance)
	return handle
}

package graphics

import "core:log"

import vma "shared:odin-vma"
import "shared:tinyobj"
import vk "vendor:vulkan"

Mesh :: struct {
	vertex_buffer:     vk.Buffer,
	vertex_allocation: vma.Allocation,
	vertex_address:    vk.DeviceAddress,
	index_buffer:      vk.Buffer,
	index_allocation:  vma.Allocation,
	index_count:       u32,
	material_index:    i32,
}

ModelHandle :: struct {
	handle: u32,
}

INVALID_MODEL :: ModelHandle {
	handle = max(u32),
}

InstanceHandle :: struct {
	handle: u32,
}

INVALID_INSTANCE :: InstanceHandle {
	handle = max(u32),
}

Model :: struct {
	meshes: [dynamic]Mesh,
	name:   string,
}

Instance :: struct {
	model:     ModelHandle,
	transform: Transform,
}

MAX_MODEL_INSTANCES :: 4096

ModelSystem :: struct {
	models:            [dynamic]Model,
	model_map:         map[string]ModelHandle,
	instances:         [dynamic]Instance,
	transforms_buffer: GpuBuffer,
}

create_model_system :: proc(engine: ^Engine) {
	total_size := vk.DeviceSize(size_of(GpuTransform) * MAX_MODEL_INSTANCES)
	engine.model_system.transforms_buffer = create_buffer(engine, total_size, .MappedStorage)
}

destroy_model_system :: proc(engine: ^Engine) {
	ms := &engine.model_system
	for &model in ms.models {
		for &mesh in model.meshes {
			vma.destroy_buffer(engine.vma_allocator, mesh.vertex_buffer, mesh.vertex_allocation)
			vma.destroy_buffer(engine.vma_allocator, mesh.index_buffer, mesh.index_allocation)
		}
		delete(model.meshes)
	}
	destroy_buffer(engine, ms.transforms_buffer)
	delete(ms.models)
	delete(ms.model_map)
	delete(ms.instances)
}

load_model :: proc(engine: ^Engine, path: string, material: MaterialHandle = INVALID_MATERIAL) -> ModelHandle {
	if handle, ok := engine.model_system.model_map[path]; ok {
		return handle
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

			vertex := Vertex {
				pos    = {
					obj.attrib.vertices[3 * index.v_idx + 0],
					obj.attrib.vertices[3 * index.v_idx + 1],
					obj.attrib.vertices[3 * index.v_idx + 2],
				},
				uv     = {
					obj.attrib.texcoords[2 * index.vt_idx + 0],
					1.0 - obj.attrib.texcoords[2 * index.vt_idx + 1],
				},
				color  = {1, 1, 1},
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

	return register_model(engine, path, vertices[:], indices[:], material)
}

register_model :: proc(
	engine: ^Engine,
	name: string,
	vertices: []Vertex,
	indices: []u32,
	material: MaterialHandle = INVALID_MATERIAL,
) -> ModelHandle {
	vertex_buf := upload_buffer(engine, raw_data(vertices), vk.DeviceSize(size_of(Vertex) * len(vertices)), .Storage)
	index_buf := upload_buffer(engine, raw_data(indices), vk.DeviceSize(size_of(u32) * len(indices)), .Index)

	material_handle := get_default_material(engine) if material == INVALID_MATERIAL else material

	mesh := Mesh {
		vertex_buffer     = vertex_buf.buffer,
		vertex_allocation = vertex_buf.alloc,
		vertex_address    = vertex_buf.ptr,
		index_buffer      = index_buf.buffer,
		index_allocation  = index_buf.alloc,
		index_count       = u32(len(indices)),
		material_index    = i32(material_handle.handle),
	}

	model := Model {
		name = name,
	}
	append(&model.meshes, mesh)

	index := u32(len(engine.model_system.models))
	append(&engine.model_system.models, model)
	engine.model_system.model_map[name] = ModelHandle {
		handle = index,
	}

	return ModelHandle{handle = index}
}

get_instance :: proc(engine: ^Engine, handle: InstanceHandle) -> ^Instance {
	return &engine.model_system.instances[handle.handle]
}

spawn_model :: proc(engine: ^Engine, model: ModelHandle, transform: Transform) -> InstanceHandle {
	index := u32(len(engine.model_system.instances))
	append(&engine.model_system.instances, Instance{model = model, transform = transform})
	return InstanceHandle{handle = index}
}

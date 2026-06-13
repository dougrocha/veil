package graphics

import "core:log"

MAX_RESOURCES :: 4096

ResourceHandle :: struct {
	handle: u32,
}

INVALID_RESOURCE :: ResourceHandle {
	handle = max(u32),
}

ResourceKind :: enum {
	Texture,
	Model,
}

Resource :: struct {
	name:      string,
	path:      string,
	kind:      ResourceKind,
	ref_count: u32,
}

ResourceSystem :: struct {
	resources:    [dynamic]Resource,
	resource_map: map[string]ResourceHandle,
}

create_resource_system :: proc(engine: ^Engine) {
}

destroy_resource_system :: proc(engine: ^Engine) {
	rs := &engine.resource_system
	delete(rs.resources)
	delete(rs.resource_map)
}

acquire_resource :: proc(engine: ^Engine, path: string, kind: ResourceKind) -> ResourceHandle {
	if handle, ok := engine.resource_system.resource_map[path]; ok {
		engine.resource_system.resources[handle.handle].ref_count += 1
		return handle
	}

	if u32(len(engine.resource_system.resources)) >= MAX_RESOURCES {
		log.errorf("Resource system is full (max: %d)", MAX_RESOURCES)
		return INVALID_RESOURCE
	}

	index := u32(len(engine.resource_system.resources))
	append(&engine.resource_system.resources, Resource{name = path, kind = kind, ref_count = 1})
	engine.resource_system.resource_map[path] = ResourceHandle {
		handle = index,
	}

	return ResourceHandle{handle = index}
}

release_resource :: proc(engine: ^Engine, handle: ResourceHandle) {
	if handle == INVALID_RESOURCE do return
	r := &engine.resource_system.resources[handle.handle]
	if r.ref_count == 0 do return
	r.ref_count -= 1
}

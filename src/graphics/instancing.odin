package graphics

import "core:log"
import "core:slice"

import "backend"

// Instancing: a pass gathers its visible (mesh, instance) pairs, batch_draw_items sorts them by
// mesh and writes each run's instance indices into the frame's id list, and the pass draws each
// run once with instance_count = run length. The vertex shader reads its transform index from
// ids[pc.instance_offset + SV_InstanceID]. Draws always use firstInstance = 0 and push the offset,
// because how the instance id includes firstInstance differs between Vulkan, HLSL and Metal.

// Every pass in a frame appends to the same list: main, transparent and every shadow view.
MAX_INSTANCE_IDS :: MAX_MODEL_INSTANCES * 16

DrawItem :: struct {
	mesh:     ^Mesh,
	instance: u32,
}

// One draw: count instances of mesh, their ids at first_id in the frame's id list.
DrawBatch :: struct {
	mesh:     ^Mesh,
	first_id: u32,
	count:    u32,
}

// Sorts items by mesh (reordering them) and returns one batch per mesh, allocated with the temp
// allocator. A full id list drops the remaining batches for this frame.
batch_draw_items :: proc(engine: ^Engine, items: []DrawItem) -> []DrawBatch {
	slice.sort_by(items, proc(a, b: DrawItem) -> bool {return uintptr(a.mesh) < uintptr(b.mesh)})

	batches := make([dynamic]DrawBatch, context.temp_allocator)
	ids := make([]u32, len(items), context.temp_allocator)
	for item, i in items do ids[i] = item.instance

	start := 0
	for i in 1 ..= len(items) {
		if i < len(items) && items[i].mesh == items[start].mesh do continue
		first, ok := instance_ids_push(engine, ids[start:i])
		if !ok do break
		append(&batches, DrawBatch{mesh = items[start].mesh, first_id = first, count = u32(i - start)})
		start = i
	}
	return batches[:]
}

// A batch of one, for draws that must keep their order (transparent, back to front).
single_draw_batch :: proc(engine: ^Engine, item: DrawItem) -> (batch: DrawBatch, ok: bool) {
	id := item.instance
	first := instance_ids_push(engine, {id}) or_return
	return {mesh = item.mesh, first_id = first, count = 1}, true
}

// Resets the frame's id list; call once per frame before any pass draws.
instance_ids_reset :: proc(engine: ^Engine) {
	current_frame_data(engine).instance_id_count = 0
}

@(private = "file")
instance_ids_push :: proc(engine: ^Engine, ids: []u32) -> (first: u32, ok: bool) {
	frame := current_frame_data(engine)
	if int(frame.instance_id_count) + len(ids) > MAX_INSTANCE_IDS {
		@(static) warned: bool
		if !warned do log.errorf("instance id list full (%d); dropping draws", MAX_INSTANCE_IDS)
		warned = true
		return 0, false
	}
	dst := ([^]u32)(backend.buffer_contents(&engine.vk_ctx, frame.instance_ids_buffer))
	copy(dst[frame.instance_id_count:][:len(ids)], ids)
	first = frame.instance_id_count
	frame.instance_id_count += u32(len(ids))
	return first, true
}

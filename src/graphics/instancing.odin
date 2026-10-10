package graphics

import "core:log"

import "backend"

// Instancing: a pass gets its visible meshes grouped into runs by mesh (draw_list.odin),
// draw_runs_upload writes each run's instance indices into the frame's id list, and the pass draws each
// run once with instance_count = run length. The vertex shader reads its transform index from
// Each draw uses firstInstance to index its instance ids and materials directly.

// Every pass in a frame appends to the same list: main, transparent and every shadow view.
// Enough for one mesh per instance in the camera and every possible shadow view.
MAX_INSTANCE_IDS :: MAX_DRAWS * (1 + MAX_SHADOW_2D_SLOTS + MAX_POINT_SHADOW_LIGHTS * 6)

// One draw: count instances of mesh, their ids at first_id in the frame's id list.
DrawBatch :: struct {
	mesh:     ^Mesh,
	first_id: u32,
	count:    u32,
}

// Writes each run's ids into the frame's id list and returns one batch per run, temp-allocated. A
// full id list drops the remaining runs for this frame.
draw_runs_upload :: proc(engine: ^Engine, runs: []DrawRun) -> []DrawBatch {
	batches := make([dynamic]DrawBatch, 0, len(runs), context.temp_allocator)
	for run in runs {
		first := instance_ids_push(engine, run.ids) or_break
		instance_materials_push(engine, first, len(run.ids), u32(run.mesh.material.index))
		append(&batches, DrawBatch{mesh = run.mesh, first_id = first, count = u32(len(run.ids))})
	}
	return batches[:]
}

@(private = "file")
instance_materials_push :: proc(engine: ^Engine, first: u32, count: int, material: u32) {
	frame := current_frame_data(engine)
	dst := backend.buffer_map_write(&engine.vk_ctx, frame.instance_materials_buffer, int(first), count)
	for &value in dst do value = material
}

// A batch of one, for draws that must keep their order (transparent, back to front).
single_draw_batch :: proc(engine: ^Engine, item: DrawItem) -> (batch: DrawBatch, ok: bool) {
	id := item.id
	first := instance_ids_push(engine, {id}) or_return
	instance_materials_push(engine, first, 1, u32(item.mesh.material.index))
	return {mesh = item.mesh, first_id = first, count = 1}, true
}

// Resets the frame's id list; call once per frame before any pass draws.
instance_ids_reset :: proc(engine: ^Engine) {
	current_frame_data(engine).instance_id_count = 0
}

// TODO: replace the @(static) warned flag.
@(private = "file")
instance_ids_push :: proc(engine: ^Engine, ids: []u32) -> (first: u32, ok: bool) {
	frame := current_frame_data(engine)
	if int(frame.instance_id_count) + len(ids) > MAX_INSTANCE_IDS {
		@(static) warned: bool
		if !warned do log.errorf("instance id list full (%d); dropping draws", MAX_INSTANCE_IDS)
		warned = true
		return 0, false
	}
	backend.buffer_write(&engine.vk_ctx, frame.instance_ids_buffer, ids, int(frame.instance_id_count))
	first = frame.instance_id_count
	frame.instance_id_count += u32(len(ids))
	return first, true
}

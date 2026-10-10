package graphics

import "core:log"

import "backend"

// Instancing: draw_runs_upload writes packed draw/material ids for each mesh run. Shaders read
// ids[SV_InstanceID + SV_StartInstanceLocation] because Slang drops the Vulkan base instance from
// SV_InstanceID. Bits 0-13 hold the material index; bits 14-28 hold the draw id.

@(shader_shared)
INSTANCE_MATERIAL_BITS :: 14
@(shader_shared)
INSTANCE_MATERIAL_MASK :: (1 << INSTANCE_MATERIAL_BITS) - 1
@(shader_shared)
INSTANCE_DRAW_ID_SHIFT :: INSTANCE_MATERIAL_BITS
@(shader_shared)
INSTANCE_DRAW_ID_BITS :: 15

#assert(MAX_DRAWS <= 1 << INSTANCE_DRAW_ID_BITS)
#assert(MAX_MATERIALS <= 1 << INSTANCE_MATERIAL_BITS)

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
		packed_ids := make([]u32, len(run.ids), context.temp_allocator)
		for id, i in run.ids {
			packed_ids[i] = (u32(id) << u32(INSTANCE_DRAW_ID_SHIFT)) | u32(run.mesh.material.index)
		}
		first := instance_ids_push(engine, packed_ids) or_break
		append(&batches, DrawBatch{mesh = run.mesh, first_id = first, count = u32(len(run.ids))})
	}
	return batches[:]
}

// A batch of one, for draws that must keep their order (transparent, back to front).
single_draw_batch :: proc(engine: ^Engine, item: DrawItem) -> (batch: DrawBatch, ok: bool) {
	packed_id := (u32(item.id) << u32(INSTANCE_DRAW_ID_SHIFT)) | u32(item.mesh.material.index)
	first := instance_ids_push(engine, {packed_id}) or_return
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

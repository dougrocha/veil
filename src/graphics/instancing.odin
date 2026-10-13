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

@(shader_shared)
DrawIndexedIndirectCommand :: struct #max_field_align(16) {
	index_count:    u32,
	instance_count: u32,
	first_index:    u32,
	vertex_offset:  i32,
	first_instance: u32,
}

#assert(size_of(DrawIndexedIndirectCommand) == 20)

#assert(MAX_DRAWS <= 1 << INSTANCE_DRAW_ID_BITS)
#assert(MAX_MATERIALS <= 1 << INSTANCE_MATERIAL_BITS)

// Every pass in a frame appends to the same list: main, transparent and every shadow view.
// Enough for one mesh per instance in the camera and every possible shadow view.
MAX_INSTANCE_IDS :: MAX_DRAWS * (1 + MAX_SHADOW_2D_SLOTS + MAX_POINT_SHADOW_LIGHTS * 6)
// 64k commands covers several views of the maximum 32k draws while keeping each slot near 1.25 MiB.
MAX_INDIRECT_COMMANDS_PER_FRAME :: 64 * 1024
// GPU culling compacts each batch serially in one invocation, so a batch caps that scan's length.
GPU_CULL_BATCH_CANDIDATES :: 1024

// One draw: count instances of mesh, their ids at first_id in the frame's id list.
DrawBatch :: struct {
	mesh:     ^Mesh,
	first_id: u32,
	count:    u32,
}

@(shader_shared)
GpuCullCandidate :: struct #max_field_align(16) {
	packed_id: u32,
	run_index: u32,
}

@(shader_shared)
GpuCullRun :: struct #max_field_align(16) {
	first_candidate: u32,
	candidate_count: u32,
	first_index:     u32,
	vertex_offset:   i32,
	index_count:     u32,
	instance_count:  u32,
	first_instance:  u32,
	_reserved:       u32,
	bounds_center:   Vec4,
	bounds_extents:  Vec4,
}

@(shader_shared)
GpuCullPushConstants :: struct #max_field_align(16) {
	candidates:      backend.GPUPtr(GpuCullCandidate),
	runs:            backend.GPUPtr(GpuCullRun),
	transforms:      backend.GPUPtr(GpuTransform),
	planes:          backend.GPUPtr(Vec4),
	output_ids:      backend.GPUPtr(u32),
	commands:        backend.GPUPtr(DrawIndexedIndirectCommand),
	candidate_count: u32,
	run_count:       u32,
	init_commands:   u32,
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

// Appends up to count commands to this frame's mapped indirect buffer.
draw_batches_indirect_upload :: proc(engine: ^Engine, batches: []DrawBatch, count: int) -> int {
	frame := current_frame_data(engine)
	start := int(frame.indirect_command_count)
	assert(count <= len(batches) && start + count <= MAX_INDIRECT_COMMANDS_PER_FRAME)
	commands := backend.buffer_map_write(&engine.vk_ctx, frame.indirect_buffer, start, count)
	for batch, i in batches[:count] {
		mesh := batch.mesh
		commands[i] = DrawIndexedIndirectCommand {
			index_count    = mesh.index_count,
			instance_count = batch.count,
			first_index    = mesh.first_index,
			vertex_offset  = i32(mesh.first_vertex),
			first_instance = batch.first_id,
		}
	}
	frame.indirect_command_count += u32(count)
	return start
}

// A batch of one, for draws that must keep their order (transparent, back to front).
single_draw_batch :: proc(engine: ^Engine, item: DrawItem) -> (batch: DrawBatch, ok: bool) {
	packed_id := (u32(item.id) << u32(INSTANCE_DRAW_ID_SHIFT)) | u32(item.mesh.material.index)
	first := instance_ids_push(engine, {packed_id}) or_return
	return {mesh = item.mesh, first_id = first, count = 1}, true
}

// Resets the frame's id list; call once per frame before any pass draws.
instance_ids_reset :: proc(engine: ^Engine) {
	frame := current_frame_data(engine)
	frame.instance_id_count = 0
	frame.indirect_command_count = 0
}

indirect_commands_available :: proc(engine: ^Engine) -> int {
	return MAX_INDIRECT_COMMANDS_PER_FRAME - int(current_frame_data(engine).indirect_command_count)
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

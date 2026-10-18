package graphics

// Owns the slot's linear instance id and indirect buffers end to end. The pass builders allocate the
// spans, upload copies them, and record encodes them. The packing order is fixed by frame_build's call order.

import "backend"

// Frame-wide caps on instance ids and indirect commands. Every push in a frame draws from the same budget.
FrameBudget :: struct {
	instance_ids, indirect_commands: u32,
}

FRAME_BUDGET_DEFAULT :: FrameBudget{MAX_INSTANCE_IDS, MAX_INDIRECT_COMMANDS_PER_FRAME}

// A run of entries in the slot's instance id buffer, by first index and count.
InstanceSpan :: struct {
	first, count: u32,
}

// A run of entries in the slot's indirect buffer, by first index and count.
IndirectSpan :: struct {
	first, count: u32,
}

// One draw call. Used for draws past the indirect budget and for transparent singles.
DirectDraw :: struct {
	index_count, first_index: u32,
	vertex_offset:            i32,
	instances:                InstanceSpan,
	triangles:                u64,
}

// Exact counts the encode will emit for a DrawGroups or a cull layout.
DrawCounters :: struct {
	draw_calls, indirect_calls: u32,
	triangles:                  u64,
	candidate_instances:        u32,
	candidate_triangles:        u64,
}

draw_counters_add :: proc(dst: ^DrawCounters, src: DrawCounters) {
	dst.draw_calls += src.draw_calls
	dst.indirect_calls += src.indirect_calls
	dst.triangles += src.triangles
	dst.candidate_instances += src.candidate_instances
	dst.candidate_triangles += src.candidate_triangles
}

// One pipeline kind. Commands within the indirect budget go in `indirect`; the overflow is drawn
// directly from `direct`.
DrawGroup :: struct {
	kind:     PipelineKind,
	indirect: IndirectSpan,
	direct:   []DirectDraw,
}

// The draw groups for one view, plus the counts its encode will emit.
DrawGroups :: struct {
	groups:   []DrawGroup,
	counters: DrawCounters,
}

// One transparent draw and its pipeline kind, kept in back to front order.
TransparentDraw :: struct {
	kind: PipelineKind,
	draw: DirectDraw,
}

// Collects a frame's instance ids and indirect commands against its FrameBudget.
LayoutBuilder :: struct {
	budget:   FrameBudget,
	ids:      [dynamic]u32,
	commands: [dynamic]DrawIndexedIndirectCommand,
	dropped:  int,
}

// The bytes frame_upload copies into the slot's buffers, and the runs dropped for the budget.
FrameLayout :: struct {
	instance_ids: []u32,
	indirect:     []DrawIndexedIndirectCommand,
	dropped_runs: int,
}

layout_builder_make :: proc(budget := FRAME_BUDGET_DEFAULT) -> LayoutBuilder {
	assert(budget.instance_ids <= MAX_INSTANCE_IDS)
	assert(budget.indirect_commands <= MAX_INDIRECT_COMMANDS_PER_FRAME)
	return {
		budget = budget,
		ids = make([dynamic]u32, context.temp_allocator),
		commands = make([dynamic]DrawIndexedIndirectCommand, context.temp_allocator),
	}
}

// Packs the runs' ids and sorts their draws into groups. group_kind overrides each run's kind; shadow
// passes use it to draw one fixed kind. A full id list drops the remaining runs in this call and reports it.
layout_push_runs :: proc(
	b: ^LayoutBuilder,
	runs: []DrawRun,
	group_kind: Maybe(PipelineKind),
) -> (
	draws: DrawGroups,
	dropped_any: bool,
) {
	groups := make([dynamic]DrawGroup, context.temp_allocator)
	direct := make([dynamic]DirectDraw, context.temp_allocator)
	group_start := 0
	for run, i in runs {
		if len(b.ids) + len(run.ids) > int(b.budget.instance_ids) {
			b.dropped += len(runs) - i
			dropped_any = true
			break
		}
		kind := run.kind
		if fixed, ok := group_kind.(PipelineKind); ok do kind = fixed
		if len(groups) == 0 || groups[len(groups) - 1].kind != kind {
			if len(groups) > 0 do groups[len(groups) - 1].direct = direct[group_start:]
			group_start = len(direct)
			append(&groups, DrawGroup{kind = kind, indirect = {first = u32(len(b.commands))}})
		}
		first := u32(len(b.ids))
		for id in run.ids do append(&b.ids, instance_id_pack(id, run.mesh.material))
		mesh := run.mesh
		draw := DirectDraw {
			index_count   = mesh.index_count,
			first_index   = mesh.first_index,
			vertex_offset = i32(mesh.first_vertex),
			instances     = {first, u32(len(run.ids))},
			triangles     = u64(mesh.index_count / 3 * u32(len(run.ids))),
		}
		if len(b.commands) < int(b.budget.indirect_commands) {
			group := &groups[len(groups) - 1]
			if group.indirect.count == 0 do draws.counters.indirect_calls += 1
			group.indirect.count += 1
			append(
				&b.commands,
				DrawIndexedIndirectCommand {
					mesh.index_count,
					draw.instances.count,
					mesh.first_index,
					i32(mesh.first_vertex),
					first,
				},
			)
		} else {
			append(&direct, draw)
		}
		draws.counters.draw_calls += 1
		draws.counters.triangles += draw.triangles
	}
	if len(groups) > 0 do groups[len(groups) - 1].direct = direct[group_start:]
	draws.groups = groups[:]
	return
}

// One instance for a draw that must keep its order, such as transparent back to front.
// nil when the id budget is full.
layout_push_single :: proc(b: ^LayoutBuilder, item: DrawItem) -> Maybe(DirectDraw) {
	if len(b.ids) >= int(b.budget.instance_ids) {
		b.dropped += 1
		return nil
	}
	first := u32(len(b.ids))
	append(&b.ids, instance_id_pack(item.id, item.mesh.material))
	mesh := item.mesh
	return DirectDraw {
		index_count = mesh.index_count,
		first_index = mesh.first_index,
		vertex_offset = i32(mesh.first_vertex),
		instances = {first, 1},
		triangles = u64(mesh.index_count / 3),
	}
}

layout_finish :: proc(b: ^LayoutBuilder) -> FrameLayout {
	return {instance_ids = b.ids[:], indirect = b.commands[:], dropped_runs = b.dropped}
}

layout_upload :: proc(r: ^Recorder, layout: ^FrameLayout) {
	if len(layout.instance_ids) > 0 {
		backend.buffer_write_slice(r.ctx, r.frame.instance_ids_buffer, layout.instance_ids)
	}
	if len(layout.indirect) > 0 {
		backend.buffer_write_slice(r.ctx, r.frame.indirect_buffer, layout.indirect)
	}
}

layout_record_groups :: proc(r: ^Recorder, encoder: backend.RenderEncoder, draws: DrawGroups, pc: ^$P) {
	backend.pipeline_push(encoder, pc)
	for group in draws.groups {
		backend.pipeline_bind(encoder, rec_pipeline(r, group.kind))
		if group.indirect.count > 0 {
			backend.cmd_draw_indexed_indirect(
				encoder,
				r.frame.indirect_buffer,
				u64(group.indirect.first) * u64(size_of(DrawIndexedIndirectCommand)),
				group.indirect.count,
				u32(size_of(DrawIndexedIndirectCommand)),
			)
			r.tally.indirect_calls += 1
			r.tally.draw_calls += group.indirect.count
		}
		for draw in group.direct do layout_record_direct(r, encoder, draw)
	}
}

layout_record_direct :: proc(r: ^Recorder, encoder: backend.RenderEncoder, draw: DirectDraw) {
	backend.cmd_draw_indexed(
		encoder,
		draw.index_count,
		draw.instances.count,
		draw.first_index,
		draw.vertex_offset,
		draw.instances.first,
	)
	r.tally.draw_calls += 1
}

// The fields every mesh draw in a pass shares. Frame buffers and the material buffer keep their
// addresses for the whole pass.
rec_mesh_push_constants :: proc(r: ^Recorder) -> MeshPushConstants {
	return {
		scene_data = rec_scene_data(r),
		vertex_buffer = r.geometry.vertices,
		material_buffer = r.geometry.materials,
		transform_buffer = backend.buffer_address(r.ctx, r.frame.transforms_buffer),
		instance_ids = backend.buffer_address(r.ctx, r.frame.instance_ids_buffer),
	}
}

// Back to front, one draw per mesh so the order holds.
layout_record_transparent :: proc(r: ^Recorder, encoder: backend.RenderEncoder, draws: []TransparentDraw) {
	pc := rec_mesh_push_constants(r)
	bound: Maybe(PipelineKind)
	for draw in draws {
		if bound != draw.kind {
			backend.pipeline_bind(encoder, rec_pipeline(r, draw.kind))
			backend.pipeline_push(encoder, &pc)
			bound = draw.kind
		}
		layout_record_direct(r, encoder, draw.draw)
	}
}

// The cull compute's inputs: candidate ids, one run per batch, and the frustum planes.
CullUpload :: struct {
	candidates: []GpuCullCandidate,
	runs:       []GpuCullRun,
	planes:     [6]Vec4,
}

// One pipeline kind's commands in cull_commands. These are not the CPU indirect buffer.
CullGroup :: struct {
	kind:       PipelineKind,
	commands:   IndirectSpan,
	draw_count: u32,
}

// The draw groups over the GPU cull output, plus the counts its encode will emit.
CullDraws :: struct {
	groups:                       []CullGroup,
	batch_count, candidate_count: u32,
	counters:                     DrawCounters,
}

// Builds the cull inputs and draw groups. ok = false when the candidates or batches exceed the budget,
// and the caller falls back to CPU culling.
cull_layout_build :: proc(
	runs: []DrawRun,
	frustum: Frustum,
	budget: FrameBudget,
) -> (
	upload: CullUpload,
	draws: CullDraws,
	ok: bool,
) {
	candidate_count, batch_count: int
	for run in runs {
		candidate_count += len(run.ids)
		batch_count += gpu_cull_batch_count(len(run.ids))
		if candidate_count > int(budget.instance_ids) || batch_count > int(budget.indirect_commands) do return
	}
	candidates := make([dynamic]GpuCullCandidate, 0, candidate_count, context.temp_allocator)
	run_data := make([dynamic]GpuCullRun, 0, batch_count, context.temp_allocator)
	groups := make([dynamic]CullGroup, context.temp_allocator)
	// Batches stay in run order and candidate order, so each batch's output lands at its own
	// first_candidate.
	for run in runs {
		if len(groups) == 0 || groups[len(groups) - 1].kind != run.kind {
			append(&groups, CullGroup{kind = run.kind, commands = {first = u32(len(run_data))}})
		}
		mesh := run.mesh
		run_batches := gpu_cull_batch_count(len(run.ids))
		for batch_index in 0 ..< run_batches {
			first := min(batch_index * GPU_CULL_BATCH_CANDIDATES, len(run.ids))
			last := min(first + GPU_CULL_BATCH_CANDIDATES, len(run.ids))
			batch := u32(len(run_data))
			append(
				&run_data,
				GpuCullRun {
					first_candidate = u32(len(candidates)),
					candidate_count = u32(last - first),
					first_index = mesh.first_index,
					vertex_offset = i32(mesh.first_vertex),
					index_count = mesh.index_count,
					bounds_center = {mesh.bounds.center.x, mesh.bounds.center.y, mesh.bounds.center.z, 0},
					bounds_extents = {mesh.bounds.extents.x, mesh.bounds.extents.y, mesh.bounds.extents.z, 0},
				},
			)
			for id in run.ids[first:last] {
				append(
					&candidates,
					GpuCullCandidate{packed_id = instance_id_pack(id, mesh.material), run_index = batch},
				)
			}
			groups[len(groups) - 1].commands.count += 1
		}
		groups[len(groups) - 1].draw_count += 1
		draws.counters.draw_calls += 1
		draws.counters.candidate_instances += u32(len(run.ids))
		draws.counters.candidate_triangles += u64(mesh.index_count / 3) * u64(len(run.ids))
	}
	for plane, i in frustum.planes {
		upload.planes[i] = {plane.normal.x, plane.normal.y, plane.normal.z, plane.distance}
	}
	upload.candidates = candidates[:]
	upload.runs = run_data[:]
	draws.groups = groups[:]
	draws.batch_count = u32(batch_count)
	draws.candidate_count = u32(candidate_count)
	draws.counters.indirect_calls = u32(len(groups))
	ok = true
	return
}

// Commands a run takes: one per GPU_CULL_BATCH_CANDIDATES ids.
// An empty run keeps one, so its draw stays counted.
gpu_cull_batch_count :: proc(id_count: int) -> int {
	return max(1, (id_count + GPU_CULL_BATCH_CANDIDATES - 1) / GPU_CULL_BATCH_CANDIDATES)
}

cull_upload :: proc(r: ^Recorder, upload: ^CullUpload) {
	if len(upload.runs) == 0 do return
	if len(upload.candidates) > 0 do backend.buffer_write_slice(r.ctx, r.frame.cull_candidates, upload.candidates)
	backend.buffer_write_slice(r.ctx, r.frame.cull_runs, upload.runs)
	backend.buffer_write_slice(r.ctx, r.frame.cull_planes, upload.planes[:])
}

cull_record_dispatch :: proc(r: ^Recorder, upload: ^CullUpload, readback: bool) {
	batch_count := len(upload.runs)
	candidate_count := len(upload.candidates)
	if batch_count == 0 do return
	pc := GpuCullPushConstants {
		candidates      = backend.buffer_address(r.ctx, r.frame.cull_candidates),
		runs            = backend.buffer_address(r.ctx, r.frame.cull_runs),
		transforms      = backend.buffer_address(r.ctx, r.frame.transforms_buffer),
		planes          = backend.buffer_address(r.ctx, r.frame.cull_planes),
		output_ids      = backend.buffer_address(r.ctx, r.frame.cull_output_ids),
		commands        = backend.buffer_address(r.ctx, r.frame.cull_commands),
		candidate_count = u32(candidate_count),
		run_count       = u32(batch_count),
	}
	scope := gpu_scope_begin(r, "culling")
	defer gpu_scope_end(r, scope)
	encoder := backend.begin_compute_pass(r.cmd)
	backend.cmd_barrier_host_write_to_compute(encoder)
	backend.pipeline_bind_compute(encoder, rec_pipeline(r, .Gpu_Cull))
	pc.init_commands = 1
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, (u32(batch_count) + 255) / 256, 1, 1)
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	pc.init_commands = 0
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, (u32(candidate_count) + 255) / 256, 1, 1)
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	pc.init_commands = 2
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, (u32(batch_count) + 255) / 256, 1, 1)
	// Every culled frame copies the commands for the latent visibility stats; the slot's fence covers the read.
	backend.cmd_barrier_compute_write_to_copy_read(encoder)
	backend.cmd_copy_buffer(r.cmd, r.frame.cull_commands, r.frame.cull_readback_commands, batch_count)
	backend.cmd_barrier_transfer_write_to_host_read(r.cmd, r.frame.cull_readback_commands)
	if readback {
		// A zero-size copy is invalid. Runs can all be empty, which leaves no candidates to read back.
		if candidate_count > 0 {
			backend.cmd_copy_buffer(r.cmd, r.frame.cull_output_ids, r.frame.cull_readback_ids, candidate_count)
			backend.cmd_barrier_transfer_write_to_host_read(r.cmd, r.frame.cull_readback_ids)
		}
	}
	backend.cmd_barrier_compute_write_to_draw_read(encoder)
	backend.end_compute_pass(encoder)
}

cull_record_groups :: proc(r: ^Recorder, encoder: backend.RenderEncoder, draws: CullDraws, pc: ^MeshPushConstants) {
	pc.instance_ids = backend.buffer_address(r.ctx, r.frame.cull_output_ids)
	// Each run owns gpu_cull_batch_count commands in run order, so a group's commands are contiguous too.
	for group in draws.groups {
		backend.pipeline_bind(encoder, rec_pipeline(r, group.kind))
		backend.pipeline_push(encoder, pc)
		backend.cmd_draw_indexed_indirect(
			encoder,
			r.frame.cull_commands,
			u64(group.commands.first) * u64(size_of(DrawIndexedIndirectCommand)),
			group.commands.count,
			u32(size_of(DrawIndexedIndirectCommand)),
		)
		r.tally.indirect_calls += 1
		r.tally.draw_calls += group.draw_count
	}
}

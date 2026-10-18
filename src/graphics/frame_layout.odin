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

// The cull compute's inputs: packed candidate ids, one run per batch, and the views they test against.
// Main's candidates, batches and outputs come first, so main owns [0, n) of each.
CullUpload :: struct {
	candidates: []u32,
	runs:       []GpuCullRun,
	views:      []GpuCullView,
}

// The frame's one cull dispatch, ahead of every pass that draws its output. Main's range is also what the
// stats and validator read back.
CullPass :: struct {
	upload:                        CullUpload,
	main_batches, main_candidates: u32,
	readback:                      bool, // debug: copy main's commands and ids back for validation
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

// One view's draws: CPU-filtered into the layout, or GPU-culled.
ViewDraws :: union #no_nil {
	DrawGroups,
	CullDraws,
}

// Collects a frame's cull inputs against its FrameBudget. Candidates, outputs and batches each draw from
// the budget; overflow means the whole frame falls back to CPU culling.
CullBuilder :: struct {
	budget:     FrameBudget,
	candidates: [dynamic]u32,
	runs:       [dynamic]GpuCullRun,
	views:      [dynamic]GpuCullView,
	outputs:    u32,
	casters:    Maybe(u32), // first candidate of the shared shadow casters, once pushed
	overflow:   bool,
}

cull_builder_make :: proc(budget: FrameBudget) -> CullBuilder {
	assert(budget.instance_ids <= MAX_INSTANCE_IDS)
	assert(budget.indirect_commands <= MAX_INDIRECT_COMMANDS_PER_FRAME)
	return {
		budget = budget,
		candidates = make([dynamic]u32, context.temp_allocator),
		runs = make([dynamic]GpuCullRun, context.temp_allocator),
		views = make([dynamic]GpuCullView, context.temp_allocator),
	}
}

// Adds a view that keeps a candidate any of frustums holds. Returns its index.
cull_push_view :: proc(b: ^CullBuilder, frustums: []Frustum, skip_near: bool) -> u32 {
	assert(len(frustums) <= SHADOW_MAP_CASCADE_COUNT)
	if len(b.views) >= MAX_CULL_VIEWS {
		b.overflow = true
		return 0
	}
	view := GpuCullView {
		frustum_count = u32(len(frustums)),
		skip_near     = u32(skip_near),
	}
	for frustum, f in frustums {
		for plane, p in frustum.planes {
			view.planes[f * 6 + p] = {plane.normal.x, plane.normal.y, plane.normal.z, plane.distance}
		}
	}
	append(&b.views, view)
	return u32(len(b.views) - 1)
}

// Adds every shadow caster as a candidate, once per frame. Every shadow view's batches read this range.
cull_push_casters :: proc(b: ^CullBuilder, casters: ^ShadowCasters) -> u32 {
	if first, ok := b.casters.?; ok do return first
	first := u32(len(b.candidates))
	for run in casters.runs {
		for id in run.ids do append(&b.candidates, instance_id_pack(id, run.mesh.material))
	}
	if len(b.candidates) > int(b.budget.instance_ids) do b.overflow = true
	b.casters = first
	return first
}

// Main's camera view and opaque runs. Must come first, so main's batches land at command 0 and its outputs at 0.
cull_push_main :: proc(b: ^CullBuilder, runs: []DrawRun, frustum: Frustum) -> CullDraws {
	assert(len(b.runs) == 0 && len(b.candidates) == 0 && len(b.views) == 0, "main culls first")
	view := cull_push_view(b, {frustum}, false)
	return cull_push_runs(b, runs, view, nil, nil)
}

// Splits each run into batches of GPU_CULL_BATCH_CANDIDATES against one view. With shared nil the run's ids
// become new candidates (main). Otherwise the runs' ids are already candidates, consecutive from shared
// (the shadow casters). group_kind overrides each run's kind, as in layout_push_runs. Batches stay in run
// order and candidate order, and each takes the next outputs, so a view's outputs are contiguous.
// Sets b.overflow and stops when a budget is exceeded.
cull_push_runs :: proc(
	b: ^CullBuilder,
	runs: []DrawRun,
	view: u32,
	group_kind: Maybe(PipelineKind),
	shared: Maybe(u32),
) -> (
	draws: CullDraws,
) {
	groups := make([dynamic]CullGroup, context.temp_allocator)
	shared_next := shared.? or_else 0
	first_batch := u32(len(b.runs))
	for run in runs {
		kind := group_kind.? or_else run.kind
		if len(groups) == 0 || groups[len(groups) - 1].kind != kind {
			append(&groups, CullGroup{kind = kind, commands = {first = u32(len(b.runs))}})
		}
		mesh := run.mesh
		first_candidate := shared_next
		if shared == nil {
			first_candidate = u32(len(b.candidates))
			for id in run.ids do append(&b.candidates, instance_id_pack(id, mesh.material))
		}
		shared_next += u32(len(run.ids))
		for batch_index in 0 ..< gpu_cull_batch_count(len(run.ids)) {
			first := min(batch_index * GPU_CULL_BATCH_CANDIDATES, len(run.ids))
			last := min(first + GPU_CULL_BATCH_CANDIDATES, len(run.ids))
			append(
				&b.runs,
				GpuCullRun {
					first_candidate = first_candidate + u32(first),
					candidate_count = u32(last - first),
					first_output = b.outputs,
					view_index = view,
					first_index = mesh.first_index,
					vertex_offset = i32(mesh.first_vertex),
					index_count = mesh.index_count,
					bounds_center = {mesh.bounds.center.x, mesh.bounds.center.y, mesh.bounds.center.z, 0},
					bounds_extents = {mesh.bounds.extents.x, mesh.bounds.extents.y, mesh.bounds.extents.z, 0},
				},
			)
			b.outputs += u32(last - first)
			groups[len(groups) - 1].commands.count += 1
		}
		groups[len(groups) - 1].draw_count += 1
		draws.counters.draw_calls += 1
		draws.counters.candidate_instances += u32(len(run.ids))
		draws.counters.candidate_triangles += u64(mesh.index_count / 3) * u64(len(run.ids))
		if len(b.candidates) > int(b.budget.instance_ids) ||
		   b.outputs > b.budget.instance_ids ||
		   len(b.runs) > int(min(b.budget.indirect_commands, GPU_CULL_MAX_BATCHES)) {
			b.overflow = true
			return
		}
	}
	draws.groups = groups[:]
	draws.batch_count = u32(len(b.runs)) - first_batch
	draws.candidate_count = draws.counters.candidate_instances
	draws.counters.indirect_calls = u32(len(groups))
	return
}

cull_builder_finish :: proc(b: ^CullBuilder) -> CullUpload {
	return {candidates = b.candidates[:], runs = b.runs[:], views = b.views[:]}
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
	backend.buffer_write_slice(r.ctx, r.frame.cull_views, upload.views)
}

// Culls every view's batches: init the commands, test each candidate, then compact each batch.
record_cull :: proc(r: ^Recorder, p: ^CullPass) {
	batch_count := len(p.upload.runs)
	if batch_count == 0 do return
	pc := GpuCullPushConstants {
		candidates = backend.buffer_address(r.ctx, r.frame.cull_candidates),
		runs       = backend.buffer_address(r.ctx, r.frame.cull_runs),
		transforms = backend.buffer_address(r.ctx, r.frame.transforms_buffer),
		views      = backend.buffer_address(r.ctx, r.frame.cull_views),
		output_ids = backend.buffer_address(r.ctx, r.frame.cull_output_ids),
		commands   = backend.buffer_address(r.ctx, r.frame.cull_commands),
		run_count  = u32(batch_count),
	}
	per_batch := (u32(batch_count) + 255) / 256
	encoder := backend.begin_compute_pass(r.cmd)
	backend.cmd_barrier_host_write_to_compute(encoder)
	backend.pipeline_bind_compute(encoder, rec_pipeline(r, .Gpu_Cull))
	pc.init_commands = 1
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, per_batch, 1, 1)
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	pc.init_commands = 0
	backend.pipeline_push_compute(encoder, &pc)
	// x covers a batch's candidates, y is the batch. cull_push_runs keeps y within GPU_CULL_MAX_BATCHES.
	backend.cmd_dispatch(encoder, (GPU_CULL_BATCH_CANDIDATES + 255) / 256, u32(batch_count), 1)
	backend.cmd_barrier_compute_write_to_compute_read(encoder)
	pc.init_commands = 2
	backend.pipeline_push_compute(encoder, &pc)
	backend.cmd_dispatch(encoder, per_batch, 1, 1)
	if p.main_batches > 0 {
		// Every culled frame copies main's commands for the latent visibility stats; the slot's fence covers
		// the read. Main's batches are the first commands and its outputs the first ids.
		backend.cmd_barrier_compute_write_to_copy_read(encoder)
		backend.cmd_copy_buffer(r.cmd, r.frame.cull_commands, r.frame.cull_readback_commands, int(p.main_batches))
		backend.cmd_barrier_transfer_write_to_host_read(r.cmd, r.frame.cull_readback_commands)
		// A zero-size copy is invalid. Main's runs can all be empty, which leaves no candidates to read back.
		if p.readback && p.main_candidates > 0 {
			backend.cmd_copy_buffer(r.cmd, r.frame.cull_output_ids, r.frame.cull_readback_ids, int(p.main_candidates))
			backend.cmd_barrier_transfer_write_to_host_read(r.cmd, r.frame.cull_readback_ids)
		}
	}
	backend.cmd_barrier_compute_write_to_draw_read(encoder)
	backend.end_compute_pass(encoder)
}

cull_record_groups :: proc(r: ^Recorder, encoder: backend.RenderEncoder, draws: CullDraws, pc: ^$P) {
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

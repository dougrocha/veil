package main

import "core:fmt"
import gfx "veil:graphics"

main :: proc() {
	check_shared_layout()
	check_id_overflow()
	check_cull_batches()
	check_dirty_commit()
	check_overlay_views()
	check_overlay_budgets()
	check_overlay_ui_order()
	check_packet_settings()
	fmt.println(
		"PASS: shared layout, ID overflow, GPU batches/fallback, dirty-slot commit, overlay clipping/budgets, packet settings/resize",
	)
}

check_shared_layout :: proc() {
	a := gfx.Mesh {
		index_count = 6,
		first_index = 10,
		first_vertex = 2,
		material = {index = 7},
	}
	b := gfx.Mesh {
		index_count = 9,
		first_index = 20,
		first_vertex = 4,
		material = {index = 9},
	}
	layout := gfx.layout_builder_make({instance_ids = 8, indirect_commands = 1})
	shadow, dropped := gfx.layout_push_runs(&layout, {{mesh = &a, ids = {2, 3}}}, gfx.PipelineKind.Shadow)
	assert(!dropped)
	assert(shadow.counters == gfx.DrawCounters{draw_calls = 1, indirect_calls = 1, triangles = 4})
	assert(len(shadow.groups) == 1 && shadow.groups[0].kind == .Shadow)
	assert(shadow.groups[0].indirect == gfx.IndirectSpan{0, 1})
	main, _ := gfx.layout_push_runs(&layout, {{mesh = &b, kind = .Mesh, ids = {4}}}, nil)
	assert(main.counters == gfx.DrawCounters{draw_calls = 1, triangles = 3})
	assert(main.groups[0].indirect.count == 0 && len(main.groups[0].direct) == 1)
	assert(
		main.groups[0].direct[0] ==
		gfx.DirectDraw{index_count = 9, first_index = 20, vertex_offset = 4, instances = {2, 1}, triangles = 3},
	)
	transparent, ok := gfx.layout_push_single(&layout, {mesh = &b, id = 5}).(gfx.DirectDraw)
	assert(ok && transparent.instances == gfx.InstanceSpan{3, 1})
	result := gfx.layout_finish(&layout)
	assert(len(result.instance_ids) == 4 && len(result.indirect) == 1 && result.dropped_runs == 0)
	expected := [4]u32{32775, 49159, 65545, 81929}
	for value, i in result.instance_ids do assert(value == expected[i], "shadow/main/transparent packing order")
	assert(result.indirect[0] == gfx.DrawIndexedIndirectCommand{6, 2, 10, 2, 0})
}

check_id_overflow :: proc() {
	mesh := gfx.Mesh {
		index_count = 6,
		material = {index = 3},
	}
	layout := gfx.layout_builder_make({instance_ids = 3, indirect_commands = 8})
	draws, dropped := gfx.layout_push_runs(
		&layout,
		{
			{mesh = &mesh, kind = .Mesh, ids = {1, 2}},
			{mesh = &mesh, kind = .Mesh, ids = {3, 4}},
			{mesh = &mesh, kind = .Mesh, ids = {5}},
		},
		nil,
	)
	assert(dropped && draws.counters.draw_calls == 1)
	result := gfx.layout_finish(&layout)
	assert(result.dropped_runs == 2 && len(result.instance_ids) == 2 && len(result.indirect) == 1)
	assert(result.instance_ids[0] == 16387 && result.instance_ids[1] == 32771)
	single, ok := gfx.layout_push_single(&layout, {mesh = &mesh, id = 6}).(gfx.DirectDraw)
	assert(ok && single.instances == gfx.InstanceSpan{2, 1})
	assert(gfx.layout_push_single(&layout, {mesh = &mesh, id = 7}) == nil)
}

check_cull_batches :: proc() {
	a := gfx.Mesh {
		index_count = 6,
		first_index = 10,
		first_vertex = 2,
		material = {index = 7},
	}
	b := gfx.Mesh {
		index_count = 9,
		first_index = 20,
		first_vertex = 4,
		material = {index = 9},
	}
	ids_a := make([]u32, 1024, context.temp_allocator)
	ids_b := make([]u32, 1025, context.temp_allocator)
	for &id, i in ids_a do id = u32(i)
	for &id, i in ids_b do id = u32(i)
	runs := []gfx.DrawRun {
		{mesh = &a, kind = .Mesh, ids = ids_a},
		{mesh = &b, kind = .Mesh, ids = ids_b},
		{mesh = &a, kind = .Mesh_Masked, ids = nil},
	}
	upload, draws, ok := gfx.cull_layout_build(runs, {}, {instance_ids = 2049, indirect_commands = 4})
	assert(ok && len(upload.runs) == 4 && len(upload.candidates) == 2049)
	assert(draws.batch_count == 4 && draws.candidate_count == 2049)
	assert(
		draws.counters ==
		gfx.DrawCounters{draw_calls = 3, indirect_calls = 2, candidate_instances = 2049, candidate_triangles = 5123},
	)
	assert(
		len(draws.groups) == 2 &&
		draws.groups[0].commands == gfx.IndirectSpan{0, 3} &&
		draws.groups[1].commands == gfx.IndirectSpan{3, 1},
	)
	expected_first := [4]u32{0, 1024, 2048, 2049}
	expected_count := [4]u32{1024, 1024, 1, 0}
	for run, i in upload.runs {
		assert(run.first_candidate == expected_first[i] && run.candidate_count == expected_count[i])
	}
	assert(upload.candidates[0] == gfx.GpuCullCandidate{7, 0})
	assert(upload.candidates[1023] == gfx.GpuCullCandidate{16760839, 0})
	assert(upload.candidates[1024] == gfx.GpuCullCandidate{9, 1})
	assert(upload.candidates[2048] == gfx.GpuCullCandidate{16777225, 2})
	failed_upload, failed_draws, fits := gfx.cull_layout_build(runs, {}, {instance_ids = 2049, indirect_commands = 3})
	assert(
		!fits && len(failed_upload.runs) == 0 && len(failed_upload.candidates) == 0 && len(failed_draws.groups) == 0,
	)
	_, _, fits_ids := gfx.cull_layout_build(runs, {}, {instance_ids = 2048, indirect_commands = 4})
	assert(!fits_ids)
}

check_dirty_commit :: proc() {
	history: gfx.DrawHistory
	gfx.draw_history_create(&history)
	defer gfx.draw_history_destroy(&history)
	history.records[2] = {
		model = {index = 1, generation = 1},
		world = gfx.Mat4x4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1},
	}
	history.dirty[0][0] = 6
	history.dirty[1][0] = 6
	append(&history.changes, gfx.DrawChange{kind = .Update, id = 2})
	writes := gfx.transform_writes(&history, 0)
	assert(len(writes) == 1 && writes[0].id == 2 && writes[0].value.model == history.records[2].world)
	assert(history.dirty[0][0] == 6 && len(history.changes) == 1, "prepare must preserve skipped-frame changes")
	assert(len(gfx.transform_writes(&history, 0)) == 1)
	gfx.draw_history_commit(&history, 0)
	assert(history.dirty[0][0] == 0 && history.dirty[1][0] == 6 && len(history.changes) == 0)
	assert(len(gfx.transform_writes(&history, 0)) == 0 && len(gfx.transform_writes(&history, 1)) == 1)
}

check_overlay_views :: proc() {
	p := gfx.overlay_prepare(nil, {}, {100, 80})
	assert(p.draw_calls == 0 && len(p.debug_views) == 0 && len(p.ui) == 0)
	o := gfx.overlay_make()
	gfx.overlay_texture_view(&o, {index = 5}, {{-10, 60}, {40, 40}})
	gfx.overlay_texture_view(&o, {index = 6}, {{100, 0}, {20, 20}})
	gfx.overlay_texture_view(&o, {index = 7}, {{10, 10}, {0, 20}})
	gfx.overlay_texture_view(&o, {index = 8}, {{10, 10}, {20, 0}})
	p = gfx.overlay_prepare(&o, {}, {100, 80})
	assert(p.draw_calls == 1 && len(p.debug_views) == 1)
	assert(p.debug_views[0].view.index == 5)
	assert(p.debug_views[0].rect == gfx.Rect2D{{-10, 60}, {40, 40}}, "clipping must crop the requested viewport")
	assert(p.debug_views[0].clip == gfx.Rect2D{{0, 60}, {30, 20}})
	p = gfx.overlay_prepare(&o, {cluster_heatmap = true}, {100, 80})
	assert(p.draw_calls == 2 && len(p.debug_views) == 2)
	assert(p.debug_views[0].view.mode == .Texture_2D && p.debug_views[1].view.mode == .Cluster_Heatmap)
	assert(p.debug_views[1].rect == gfx.Rect2D{{0, 0}, {100, 80}})

	capped := gfx.overlay_make()
	for i in 0 ..< 64 do gfx.overlay_texture_view(&capped, {index = gfx.Index(i)}, {{0, 0}, {20, 20}})
	p = gfx.overlay_prepare(&capped, {cluster_heatmap = true}, {100, 80})
	assert(p.draw_calls == 64 && len(p.debug_views) == 64 && p.dropped_debug_views == 1)
	assert(p.debug_views[63].view.mode == .Texture_2D && p.debug_views[63].view.index == 63)
	gfx.overlay_texture_view(&capped, {index = 99}, {{0, 0}, {20, 20}})
	p = gfx.overlay_prepare(&capped, {}, {100, 80})
	assert(p.draw_calls == 64 && p.dropped_debug_views == 1)
	assert(p.debug_views[63].view.index == 63)
}

check_overlay_budgets :: proc() {
	o := gfx.overlay_make()
	for i in 0 ..< 32770 do gfx.overlay_line(&o, {f32(i), 0, 0}, {f32(i), 1, 0}, {1, 1, 1, 1})
	for i in 0 ..< 21847 do gfx.overlay_sector_triangle(&o, {f32(i), 0, 0}, {f32(i), 1, 0}, {f32(i), 0, 1}, {1, 1, 1, 1})
	gfx.overlay_line(&o, {7, 0, 0}, {8, 0, 0}, {1, 0, 0, 1}, on_top = true)
	ui := gfx.overlay_ui_batch(&o, 5)
	resize(ui, 65544)
	ui^[65531].color = {1, 2, 3, 4}
	p := gfx.overlay_prepare(&o, {}, {100, 80})
	assert(p.draw_calls == 4 && p.dropped_lines == 4 && p.dropped_ui == 2)
	assert(len(p.lines[.Tested]) == 65536 && len(p.lines[.Sector]) == 65535 && len(p.lines[.On_Top]) == 2)
	assert(p.lines[.Tested][65535].position == gfx.Vec3{32767, 1, 0})
	assert(p.lines[.Sector][65534].position == gfx.Vec3{21844, 0, 1})
	assert(p.lines[.On_Top][1].position == gfx.Vec3{8, 0, 0})
	assert(len(p.ui) == 1 && p.ui[0].atlas_texture == gfx.TextureIndex(5) && len(p.ui[0].vertices) == 65532)
	assert(p.ui[0].vertices[65531].color == [4]u8{1, 2, 3, 4})
	assert(
		len(o.lines[.Tested]) == 65540 && len(o.lines[.Sector]) == 65541 && len(ui^) == 65544,
		"preparation must not drain game-owned geometry",
	)
}

check_overlay_ui_order :: proc() {
	o := gfx.overlay_make()
	for atlas in ([?]u32{9, 3, 6, 3, 9}) {
		batch := gfx.overlay_ui_batch(&o, atlas)
		resize(batch, len(batch^) + 6)
	}
	p := gfx.overlay_prepare(&o, {}, {100, 80})
	assert(p.draw_calls == 3 && len(p.ui) == 3, "each atlas must prepare one batch")
	assert(p.ui[0].atlas_texture == 9 && p.ui[1].atlas_texture == 3 && p.ui[2].atlas_texture == 6)
	assert(len(p.ui[0].vertices) == 12 && len(p.ui[1].vertices) == 12 && len(p.ui[2].vertices) == 6)
}

check_packet_settings :: proc() {
	history: gfx.DrawHistory
	gfx.draw_history_create(&history)
	defer gfx.draw_history_destroy(&history)
	models := gfx.pool_init(1, gfx.Model)
	materials := gfx.pool_init(1, gfx.Material)
	defer gfx.pool_destroy(&models)
	defer gfx.pool_destroy(&materials)
	casters: gfx.ShadowCasters
	defer gfx.shadow_casters_destroy(&casters)
	gfx.shadow_casters_sync(
		&casters,
		{draws = gfx.draw_history_live(&history), models = &models, materials = &materials},
		nil,
	)
	lights := gfx.LightData {
		point_light_count = 1,
	}
	lights.point_lights[0] = {
		pos         = {1, 2, 3},
		range       = 10,
		shadow_near = 0.1,
		color       = {1, 1, 1},
	}
	cache: gfx.ShadowCache
	packet := gfx.FramePacket {
		camera     = gfx.camera_create(),
		lights     = &lights,
		background = gfx.Vec4{0.1, 0.2, 0.3, 1},
		settings   = gfx.RENDER_SETTINGS_DEFAULT,
	}
	input := gfx.PrepareInput {
		packet = &packet,
		history = &history,
		casters = &casters,
		cache = &cache,
		models = &models,
		materials = &materials,
		targets = {extent = {1280, 720}, bloom_extent = {640, 360}, bloom_mips = 6},
		budget = {instance_ids = 32, indirect_commands = 32},
	}
	first := gfx.frame_prepare(input)
	second := gfx.frame_prepare(input)
	assert(
		first.counters == gfx.FrameCounters{shadow_views = 6} &&
		second.counters == gfx.FrameCounters{shadow_views = 6},
	)
	assert(first.uploads.scene == second.uploads.scene)
	assert(
		len(first.shadow_plan.views) == 6 &&
		len(second.shadow_plan.views) == 6 &&
		first.passes.shadow_2d == nil &&
		first.passes.shadow_point != nil,
	)
	assert(
		len(first.uploads.point_lights) == 1 &&
		len(second.uploads.point_lights) == 1 &&
		first.uploads.point_lights[0] == second.uploads.point_lights[0],
	)
	assert(
		first.passes.main.clear_color == gfx.Vec4{0.1, 0.2, 0.3, 1} &&
		second.passes.main.clear_color == first.passes.main.clear_color,
	)
	first_cull, first_gpu := first.passes.main.opaque.(gfx.CullDraws)
	second_cull, second_gpu := second.passes.main.opaque.(gfx.CullDraws)
	assert(
		first_gpu &&
		second_gpu &&
		first_cull.candidate_count == 0 &&
		second_cull.candidate_count == 0 &&
		len(first_cull.groups) == 0 &&
		len(second_cull.groups) == 0,
	)
	assert(
		first.passes.clusters != nil &&
		second.passes.clusters != nil &&
		first.passes.particles == nil &&
		second.passes.particles == nil,
	)
	assert(
		len(first.uploads.transforms) == 0 &&
		len(second.uploads.transforms) == 0 &&
		len(first.uploads.layout.instance_ids) == 0 &&
		len(second.uploads.layout.instance_ids) == 0,
	)
	assert(
		first.uploads.scene.cluster_extent == gfx.Vec2{1280, 720} &&
		second.uploads.scene.cluster_extent == gfx.Vec2{1280, 720},
	)
	assert(first.passes.bloom.hdr_size == [2]u32{1280, 720} && first.passes.bloom.mip_sizes[0] == [2]u32{640, 360})
	assert(first.passes.bloom == second.passes.bloom && first.passes.tonemap == second.passes.tonemap)
	assert(history.high == 0 && len(history.changes) == 0 && history.dirty[0][0] == 0 && cache == gfx.ShadowCache{})

	packet.settings.gpu_cull = false
	packet.settings.shadows = false
	packet.settings.clustered_lighting = false
	packet.settings.particles = true
	packet.delta_time = 0.25
	changed := gfx.frame_prepare(input)
	cpu_draws, cpu_path := changed.passes.main.opaque.(gfx.DrawGroups)
	assert(
		changed.uploads.cull == nil &&
		cpu_path &&
		len(cpu_draws.groups) == 0 &&
		cpu_draws.counters == gfx.DrawCounters{},
	)
	assert(changed.passes.shadow_2d == nil && changed.passes.shadow_point == nil && changed.passes.clusters == nil)
	particles, particle_enabled := changed.passes.particles.(gfx.ParticlesPrep)
	assert(particle_enabled && particles.delta_time == 0.25)
	assert(changed.passes.main.particles && changed.counters.draw_calls == 1)
	assert(
		changed.uploads.scene.debug_settings.disable_shadows == 1 &&
		changed.uploads.scene.debug_settings.clustered_lighting == 0,
	)
	packet.settings.shadows = true
	changed = gfx.frame_prepare(input)
	assert(
		changed.passes.shadow_point != nil &&
		changed.passes.shadow_2d == nil &&
		changed.counters.shadow_views == 6 &&
		changed.uploads.scene.debug_settings.disable_shadows == 0,
	)
	packet.settings.shadows = false
	packet.settings.cluster_heatmap = true
	changed = gfx.frame_prepare(input)
	assert(
		changed.passes.clusters != nil && changed.passes.overlay.draw_calls == 1 && changed.counters.draw_calls == 2,
	)
	assert(changed.passes.overlay.debug_views[0].view.mode == .Cluster_Heatmap)
	packet.settings.cluster_heatmap = false
	input.cluster_validate = true
	changed = gfx.frame_prepare(input)
	assert(changed.passes.clusters != nil && changed.passes.overlay.draw_calls == 0)
	input.targets = {
		extent       = {320, 180},
		bloom_extent = {160, 90},
		bloom_mips   = 4,
	}
	changed = gfx.frame_prepare(input)
	assert(changed.uploads.scene.cluster_extent == gfx.Vec2{320, 180})
	assert(
		changed.passes.bloom.hdr_size == [2]u32{320, 180} &&
		changed.passes.bloom.mip_sizes[0] == [2]u32{160, 90} &&
		changed.passes.bloom.mip_sizes[1] == [2]u32{80, 45},
	)
	assert(changed.passes.tonemap.size == [2]u32{320, 180})
}

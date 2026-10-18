package main

import "core:fmt"
import "core:math/linalg"
import "core:strings"
import gfx "veil:graphics"
import "veil:handles"

main :: proc() {
	check_shared_layout()
	check_id_overflow()
	check_cull_batches()
	check_dirty_commit()
	check_overlay_views()
	check_overlay_budgets()
	check_overlay_ui_order()
	check_packet_settings()
	check_shadow_overflow_commit()
	check_post_levels()
	check_pass_uses()
	check_main_pass_choice()
	check_overlay_counters()
	check_pool_nil()
	fmt.println(
		"PASS: shared layout, ID overflow, GPU batches/fallback, dirty-slot commit, overlay clipping/budgets, packet settings/resize, shadow overflow commit, post levels, pass uses, main pass CPU/GPU choice, overlay counters, pool nil slot",
	)
}

// frame_build's outputs and the counters planned from its pass list.
Built :: struct {
	passes:   []gfx.Pass,
	uploads:  gfx.FrameUploads,
	plan:     gfx.ShadowPlan,
	counters: gfx.FrameCounters,
}

build_frame :: proc(input: gfx.FrameInput) -> Built {
	b: Built
	b.passes, b.uploads, b.plan = gfx.frame_build(input)
	b.counters = gfx.passes_counters(b.passes, &b.plan)
	return b
}

find_shadow :: proc(passes: []gfx.Pass, atlas: gfx.ShadowAtlasKind) -> (gfx.ShadowPass, bool) {
	for pass in passes {
		if p, ok := pass.(gfx.ShadowPass); ok && p.atlas == atlas do return p, true
	}
	return {}, false
}

// The pass kinds in list order, for example "main bloom tonemap overlay".
pass_order :: proc(passes: []gfx.Pass) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for pass in passes {
		switch p in pass {
		case gfx.ParticlesPass:
			append(&names, "particles")
		case gfx.ShadowPass:
			append(&names, "shadow:2d" if p.atlas == .Atlas_2D else "shadow:cube")
		case gfx.ClustersPass:
			append(&names, "clusters")
		case gfx.MainPass:
			append(&names, "main")
		case gfx.BloomPass:
			append(&names, "bloom")
		case gfx.TonemapPass:
			append(&names, "tonemap")
		case gfx.OverlayPass:
			append(&names, "overlay")
		}
	}
	return strings.join(names[:], " ", context.temp_allocator)
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
	assert(history.dirty[0][0] == 6 && len(history.changes) == 1, "build must preserve skipped-frame changes")
	assert(len(gfx.transform_writes(&history, 0)) == 1)
	gfx.draw_history_commit(&history, 0)
	assert(history.dirty[0][0] == 0 && history.dirty[1][0] == 6 && len(history.changes) == 0)
	assert(len(gfx.transform_writes(&history, 0)) == 0 && len(gfx.transform_writes(&history, 1)) == 1)
}

check_overlay_views :: proc() {
	p := gfx.overlay_pass_build(nil, {}, {100, 80})
	assert(p.draw_calls == 0 && len(p.debug_views) == 0 && len(p.ui) == 0)
	o := gfx.overlay_make()
	gfx.overlay_texture_view(&o, {index = 5}, {{-10, 60}, {40, 40}})
	gfx.overlay_texture_view(&o, {index = 6}, {{100, 0}, {20, 20}})
	gfx.overlay_texture_view(&o, {index = 7}, {{10, 10}, {0, 20}})
	gfx.overlay_texture_view(&o, {index = 8}, {{10, 10}, {20, 0}})
	p = gfx.overlay_pass_build(&o, {}, {100, 80})
	assert(p.draw_calls == 1 && len(p.debug_views) == 1)
	assert(p.debug_views[0].view.index == 5)
	assert(p.debug_views[0].rect == gfx.Rect2D{{-10, 60}, {40, 40}}, "clipping must crop the requested viewport")
	assert(p.debug_views[0].clip == gfx.Rect2D{{0, 60}, {30, 20}})
	p = gfx.overlay_pass_build(&o, {cluster_heatmap = true}, {100, 80})
	assert(p.draw_calls == 2 && len(p.debug_views) == 2)
	assert(p.debug_views[0].view.mode == .Texture_2D && p.debug_views[1].view.mode == .Cluster_Heatmap)
	assert(p.debug_views[1].rect == gfx.Rect2D{{0, 0}, {100, 80}})

	capped := gfx.overlay_make()
	for i in 0 ..< 64 do gfx.overlay_texture_view(&capped, {index = gfx.Index(i)}, {{0, 0}, {20, 20}})
	p = gfx.overlay_pass_build(&capped, {cluster_heatmap = true}, {100, 80})
	assert(p.draw_calls == 64 && len(p.debug_views) == 64 && p.dropped_debug_views == 1)
	assert(p.debug_views[63].view.mode == .Texture_2D && p.debug_views[63].view.index == 63)
	gfx.overlay_texture_view(&capped, {index = 99}, {{0, 0}, {20, 20}})
	p = gfx.overlay_pass_build(&capped, {}, {100, 80})
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
	p := gfx.overlay_pass_build(&o, {}, {100, 80})
	assert(p.draw_calls == 4 && p.dropped_lines == 4 && p.dropped_ui == 2)
	assert(len(p.lines[.Tested]) == 65536 && len(p.lines[.Sector]) == 65535 && len(p.lines[.On_Top]) == 2)
	assert(p.lines[.Tested][65535].position == gfx.Vec3{32767, 1, 0})
	assert(p.lines[.Sector][65534].position == gfx.Vec3{21844, 0, 1})
	assert(p.lines[.On_Top][1].position == gfx.Vec3{8, 0, 0})
	assert(len(p.ui) == 1 && p.ui[0].atlas_texture == gfx.TextureIndex(5) && len(p.ui[0].vertices) == 65532)
	assert(p.ui[0].vertices[65531].color == [4]u8{1, 2, 3, 4})
	assert(
		len(o.lines[.Tested]) == 65540 && len(o.lines[.Sector]) == 65541 && len(ui^) == 65544,
		"building must not drain game-owned geometry",
	)
}

check_overlay_ui_order :: proc() {
	o := gfx.overlay_make()
	for atlas in ([?]u32{9, 3, 6, 3, 9}) {
		batch := gfx.overlay_ui_batch(&o, atlas)
		resize(batch, len(batch^) + 6)
	}
	p := gfx.overlay_pass_build(&o, {}, {100, 80})
	assert(p.draw_calls == 3 && len(p.ui) == 3, "each atlas must produce one batch")
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
	input := gfx.FrameInput {
		packet = &packet,
		history = &history,
		casters = &casters,
		cache = &cache,
		models = &models,
		materials = &materials,
		targets = {extent = {1280, 720}, bloom_extent = {640, 360}, bloom_mips = 6},
		budget = {instance_ids = 32, indirect_commands = 32},
	}
	first := build_frame(input)
	second := build_frame(input)
	assert(first.counters == gfx.FrameCounters{shadow_views = 6} && second.counters == first.counters)
	assert(first.uploads.scene == second.uploads.scene)
	assert(len(first.plan.views) == 6 && len(second.plan.views) == 6)
	shadow_2d, has_2d := find_shadow(first.passes, .Atlas_2D)
	shadow_cube, has_cube := find_shadow(first.passes, .Cube)
	assert(!has_2d && has_cube && len(shadow_cube.views) == 6)
	assert(
		len(first.uploads.point_lights) == 1 &&
		len(second.uploads.point_lights) == 1 &&
		first.uploads.point_lights[0] == second.uploads.point_lights[0],
	)
	first_main, _ := gfx.pass_find(first.passes, gfx.MainPass)
	second_main, _ := gfx.pass_find(second.passes, gfx.MainPass)
	assert(first_main.clear_color == gfx.Vec4{0.1, 0.2, 0.3, 1} && second_main.clear_color == first_main.clear_color)
	first_cull, first_gpu := first_main.opaque.(gfx.CullDraws)
	second_cull, second_gpu := second_main.opaque.(gfx.CullDraws)
	assert(
		first_gpu &&
		second_gpu &&
		first_main.cull != nil &&
		first_cull.candidate_count == 0 &&
		second_cull.candidate_count == 0 &&
		len(first_cull.groups) == 0 &&
		len(second_cull.groups) == 0,
	)
	_, has_clusters := gfx.pass_find(first.passes, gfx.ClustersPass)
	_, has_particles := gfx.pass_find(first.passes, gfx.ParticlesPass)
	assert(has_clusters && !has_particles)
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
	first_bloom, _ := gfx.pass_find(first.passes, gfx.BloomPass)
	first_tonemap, _ := gfx.pass_find(first.passes, gfx.TonemapPass)
	assert(first_bloom.hdr_size == [2]u32{1280, 720} && first_bloom.mip_sizes[0] == [2]u32{640, 360})
	second_bloom, _ := gfx.pass_find(second.passes, gfx.BloomPass)
	second_tonemap, _ := gfx.pass_find(second.passes, gfx.TonemapPass)
	assert(first_bloom^ == second_bloom^ && first_tonemap^ == second_tonemap^)
	assert(history.high == 0 && len(history.changes) == 0 && history.dirty[0][0] == 0 && cache == gfx.ShadowCache{})

	// Execution order: particles, shadows, clusters, then the always-present tail.
	assert(pass_order(first.passes) == "shadow:cube clusters main bloom tonemap overlay")

	packet.settings.gpu_cull = false
	packet.settings.shadows = false
	packet.settings.clustered_lighting = false
	packet.settings.particles = true
	packet.delta_time = 0.25
	changed := build_frame(input)
	changed_main, _ := gfx.pass_find(changed.passes, gfx.MainPass)
	cpu_draws, cpu_path := changed_main.opaque.(gfx.DrawGroups)
	assert(
		changed_main.cull == nil &&
		!changed_main.cull_readback &&
		cpu_path &&
		len(cpu_draws.groups) == 0 &&
		cpu_draws.counters == gfx.DrawCounters{},
	)
	_, has_2d = find_shadow(changed.passes, .Atlas_2D)
	_, has_cube = find_shadow(changed.passes, .Cube)
	_, has_clusters = gfx.pass_find(changed.passes, gfx.ClustersPass)
	assert(!has_2d && !has_cube && !has_clusters)
	particles, particle_enabled := gfx.pass_find(changed.passes, gfx.ParticlesPass)
	assert(particle_enabled && particles.delta_time == 0.25)
	assert(changed_main.particles && changed.counters.draw_calls == 1)
	assert(pass_order(changed.passes) == "particles main bloom tonemap overlay")
	assert(
		changed.uploads.scene.debug_settings.disable_shadows == 1 &&
		changed.uploads.scene.debug_settings.clustered_lighting == 0,
	)
	packet.settings.shadows = true
	changed = build_frame(input)
	_, has_2d = find_shadow(changed.passes, .Atlas_2D)
	_, has_cube = find_shadow(changed.passes, .Cube)
	assert(
		has_cube &&
		!has_2d &&
		changed.counters.shadow_views == 6 &&
		changed.uploads.scene.debug_settings.disable_shadows == 0,
	)
	packet.settings.shadows = false
	packet.settings.cluster_heatmap = true
	changed = build_frame(input)
	changed_overlay, _ := gfx.pass_find(changed.passes, gfx.OverlayPass)
	_, has_clusters = gfx.pass_find(changed.passes, gfx.ClustersPass)
	assert(has_clusters && changed_overlay.draw_calls == 1 && changed.counters.draw_calls == 2)
	assert(changed_overlay.debug_views[0].view.mode == .Cluster_Heatmap)
	packet.settings.cluster_heatmap = false
	input.cluster_validate = true
	changed = build_frame(input)
	changed_overlay, _ = gfx.pass_find(changed.passes, gfx.OverlayPass)
	_, has_clusters = gfx.pass_find(changed.passes, gfx.ClustersPass)
	assert(has_clusters && changed_overlay.draw_calls == 0)
	input.targets = {
		extent       = {320, 180},
		bloom_extent = {160, 90},
		bloom_mips   = 4,
	}
	changed = build_frame(input)
	assert(changed.uploads.scene.cluster_extent == gfx.Vec2{320, 180})
	small_bloom, _ := gfx.pass_find(changed.passes, gfx.BloomPass)
	small_tonemap, _ := gfx.pass_find(changed.passes, gfx.TonemapPass)
	assert(
		small_bloom.hdr_size == [2]u32{320, 180} &&
		small_bloom.mip_sizes[0] == [2]u32{160, 90} &&
		small_bloom.mip_sizes[1] == [2]u32{80, 45},
	)
	assert(small_tonemap.size == [2]u32{320, 180})
}

// The bloom and tonemap passes must agree on the level count: strength is divided by it.
check_post_levels :: proc() {
	targets := gfx.TargetInfo {
		extent       = {1280, 720},
		bloom_extent = {640, 360},
		bloom_mips   = 6,
	}
	post := gfx.POST_SETTINGS_DEFAULT
	bloom, tonemap := gfx.post_passes_build(targets, post)
	assert(bloom.levels == gfx.bloom_level_count(targets, post.bloom_max_levels) && bloom.levels > 1)
	assert(tonemap.bloom_strength == post.bloom_strength / f32(bloom.levels))
	assert(tonemap.exposure == post.exposure && tonemap.size == [2]u32{1280, 720})
	post.bloom_max_levels = 2
	bloom, tonemap = gfx.post_passes_build(targets, post)
	assert(bloom.levels == 2 && tonemap.bloom_strength == post.bloom_strength / 2)
	targets.bloom_mips = 1
	bloom, tonemap = gfx.post_passes_build(targets, post)
	assert(bloom.levels == 1 && tonemap.bloom_strength == post.bloom_strength)
}

// Main and Overlay must declare both atlases readable so they stay valid when the shadow passes are skipped.
check_pass_uses :: proc() {
	has_use :: proc(uses: []gfx.PassUse, use: gfx.PassUse) -> bool {
		for u in uses do if u == use do return true
		return false
	}
	for pass in ([?]gfx.Pass{gfx.MainPass{}, gfx.OverlayPass{}}) {
		uses := gfx.pass_uses(pass)
		assert(has_use(uses, {.Shadow_2D, .Depth_Read}) && has_use(uses, {.Shadow_Cube, .Depth_Read}))
	}
	assert(has_use(gfx.pass_uses(gfx.ShadowPass{atlas = .Atlas_2D}), {.Shadow_2D, .Depth_Write}))
	assert(has_use(gfx.pass_uses(gfx.ShadowPass{atlas = .Cube}), {.Shadow_Cube, .Depth_Write}))
	assert(len(gfx.pass_uses(gfx.ParticlesPass{})) == 0 && len(gfx.pass_uses(gfx.ClustersPass{})) == 0)
}

// One opaque mesh in the scene: the main pass takes the GPU path when it fits the budget and falls back to
// the CPU list when it does not.
check_main_pass_choice :: proc() {
	history: gfx.DrawHistory
	gfx.draw_history_create(&history)
	defer gfx.draw_history_destroy(&history)
	models := gfx.pool_init(1, gfx.Model)
	materials := gfx.pool_init(1, gfx.Material)
	defer gfx.pool_destroy(&models)
	defer gfx.pool_destroy(&materials)
	material := gfx.pool_alloc(&materials, gfx.Material{})
	model := gfx.Model {
		meshes = make([dynamic]gfx.Mesh),
	}
	defer delete(model.meshes)
	append(&model.meshes, gfx.Mesh{index_count = 6, material = material, bounds = {extents = {1, 1, 1}}})
	handle := gfx.pool_alloc(&models, model)
	history.records[0] = {
		model = handle,
		bounds = {radius = 2},
		world = gfx.Mat4x4(1) * linalg.matrix4_translate_f32({0, 0, -3}),
	}
	history.high = 1
	lights: gfx.LightData
	packet := gfx.FramePacket {
		camera   = gfx.camera_create(),
		lights   = &lights,
		settings = gfx.RENDER_SETTINGS_DEFAULT,
	}
	packet.settings.gpu_cull = true
	input := gfx.FrameInput {
		packet = &packet,
		history = &history,
		models = &models,
		materials = &materials,
		targets = {extent = {1280, 720}, bloom_extent = {640, 360}, bloom_mips = 6},
		budget = {instance_ids = 32, indirect_commands = 32},
		cull_readback = true,
	}
	layout := gfx.layout_builder_make(input.budget)
	gpu := gfx.main_pass_build(input, &layout)
	cull, is_gpu := gpu.opaque.(gfx.CullDraws)
	assert(is_gpu && gpu.cull != nil && gpu.cull_readback && cull.candidate_count == 1)
	assert(
		gpu.counters.candidate_instances == 1 && gpu.draws_visible == 0,
		"GPU path reports candidates, not visibility",
	)

	input.cull_readback = false
	layout = gfx.layout_builder_make(input.budget)
	assert(!gfx.main_pass_build(input, &layout).cull_readback)

	// Too small for the cull layout: falls back to the CPU list, which then draws what fits.
	input.cull_readback = true
	input.budget = {
		instance_ids      = 1,
		indirect_commands = 0,
	}
	layout = gfx.layout_builder_make(input.budget)
	cpu := gfx.main_pass_build(input, &layout)
	cpu_draws, is_cpu := cpu.opaque.(gfx.DrawGroups)
	assert(is_cpu && cpu.cull == nil && !cpu.cull_readback)
	assert(cpu.draws_visible == 1 && cpu_draws.counters.draw_calls == 1 && cpu.counters.draw_calls == 1)

	packet.settings.gpu_cull = false
	input.budget = {
		instance_ids      = 32,
		indirect_commands = 32,
	}
	layout = gfx.layout_builder_make(input.budget)
	cpu = gfx.main_pass_build(input, &layout)
	_, is_cpu = cpu.opaque.(gfx.DrawGroups)
	assert(is_cpu && cpu.cull == nil && !cpu.cull_readback && cpu.draws_visible == 1)
}

// Overlay draws and drops flow into the frame counters next to the main pass's.
check_overlay_counters :: proc() {
	o := gfx.overlay_make()
	gfx.overlay_line(&o, {0, 0, 0}, {1, 0, 0}, {1, 1, 1, 1})
	ui := gfx.overlay_ui_batch(&o, 5)
	resize(ui, 6)
	gfx.overlay_texture_view(&o, {index = 5}, {{0, 0}, {20, 20}})
	overlay := gfx.overlay_pass_build(&o, {}, {100, 80})
	main := gfx.MainPass {
		counters = {draw_calls = 3, indirect_calls = 1, triangles = 12},
	}
	plan := gfx.ShadowPlan {
		views_cached = 2,
	}
	counters := gfx.passes_counters({main, overlay}, &plan)
	assert(overlay.draw_calls == 3)
	assert(counters.draw_calls == 6 && counters.indirect_calls == 1 && counters.triangles == 12)
	assert(counters.shadow_views_cached == 2 && counters.shadow_views == 0)
}

// A point light whose shadow faces lost casters to the budget must stay uncached, so it renders again.
check_shadow_overflow_commit :: proc() {
	history: gfx.DrawHistory
	gfx.draw_history_create(&history)
	defer gfx.draw_history_destroy(&history)
	models := gfx.pool_init(1, gfx.Model)
	materials := gfx.pool_init(1, gfx.Material)
	defer gfx.pool_destroy(&models)
	defer gfx.pool_destroy(&materials)
	model := gfx.Model {
		meshes = make([dynamic]gfx.Mesh),
	}
	defer delete(model.meshes)
	append(&model.meshes, gfx.Mesh{index_count = 6, bounds = {extents = {1, 1, 1}}})
	handle := gfx.pool_alloc(&models, model)
	draws := []gfx.DrawRecord {
		{
			model = handle,
			bounds = {radius = 2},
			world = gfx.Mat4x4(1) * linalg.matrix4_translate_f32({0, 0, -3}),
			casts_shadow = true,
		},
	}
	casters: gfx.ShadowCasters
	defer gfx.shadow_casters_destroy(&casters)
	gfx.shadow_casters_sync(&casters, {draws = draws, models = &models, materials = &materials}, nil)

	lights := gfx.LightData {
		point_light_count = 1,
	}
	lights.point_lights[0] = {
		range       = 10,
		shadow_near = 0.1,
		color       = {1, 1, 1},
	}
	cache: gfx.ShadowCache
	packet := gfx.FramePacket {
		camera   = gfx.camera_create(),
		lights   = &lights,
		settings = gfx.RENDER_SETTINGS_DEFAULT,
	}
	input := gfx.FrameInput {
		packet = &packet,
		history = &history,
		casters = &casters,
		cache = &cache,
		models = &models,
		materials = &materials,
		targets = {extent = {1280, 720}, bloom_extent = {640, 360}, bloom_mips = 6},
		budget = {instance_ids = 32, indirect_commands = 32},
	}
	fitting := build_frame(input)
	assert(!fitting.plan.dropped_point[0])
	gfx.shadow_cache_commit(&cache, &fitting.plan, &lights)
	assert(cache.point[0].valid)

	cache = {}
	input.budget = {}
	starved := build_frame(input)
	assert(starved.plan.dropped_point[0] && starved.uploads.layout.dropped_runs > 0)
	gfx.shadow_cache_commit(&cache, &starved.plan, &lights)
	assert(!cache.point[0].valid)
	assert(len(build_frame(input).plan.views) == 6)
}

check_pool_nil :: proc() {
	Item :: struct {
		value: int,
	}
	pool := handles.pool_init(2, Item)
	defer handles.pool_destroy(&pool)
	handles.pool_set_nil(&pool, Item{value = 7})

	// The zero handle reads as the nil value, and pool_set_nil changes it.
	assert(handles.pool_get(&pool, {}).value == 7)
	handles.pool_set_nil(&pool, Item{value = 9})
	assert(handles.pool_get(&pool, {}).value == 9)
	handles.pool_set_nil(&pool, Item{value = 7})
	assert(!handles.pool_is_valid(&pool, {}))
	assert(handles.pool_live_count(&pool) == 0 && handles.pool_capacity(&pool) == 2)

	// Slot 0 is never handed out, and max_capacity slots stay usable.
	a := handles.pool_alloc(&pool, Item{value = 1})
	b := handles.pool_alloc(&pool, Item{value = 2})
	assert(a.index == 1 && b.index == 2 && handles.pool_is_full(&pool))
	assert(handles.pool_live_count(&pool) == 2)
	assert(handles.pool_get(&pool, a).value == 1 && handles.pool_get(&pool, {}).value == 7)

	// A freed handle is no longer valid (pool_get on it asserts), and the slot is reused.
	handles.pool_free(&pool, a)
	assert(!handles.pool_is_valid(&pool, a) && handles.pool_live_count(&pool) == 1)
	c := handles.pool_alloc(&pool, Item{value = 3})
	assert(c.index == a.index && c.generation != a.generation && !handles.pool_is_valid(&pool, a))
	handles.pool_free(&pool, b)
	handles.pool_free(&pool, c)
	assert(handles.pool_live_count(&pool) == 0)
}

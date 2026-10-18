package graphics

import "backend"

// Everything the main pass records, decided while building.
MainPass :: struct {
	opaque:                       ViewDraws, // GPU-culled or CPU-culled, chosen while building
	transparent:                  []TransparentDraw,
	clear_color:                  Vec4,
	sky, particles:               bool,
	counters:                     DrawCounters,
	draws_visible, meshes_culled: u32,
}

// With a CullBuilder the opaque draws are GPU-culled, in its first slots; without one they are CPU-culled
// into the layout. If the builder overflows, frame_build discards this pass and builds again without it.
main_pass_build :: proc(input: FrameInput, layout: ^LayoutBuilder, cull: ^CullBuilder) -> (p: MainPass) {
	packet := input.packet
	view := DrawInput {
		draws     = draw_history_live(input.history),
		models    = input.models,
		materials = input.materials,
	}
	aspect := extent_aspect(input.targets.extent)
	frustum := frustum_create_from_camera(&packet.camera, aspect)
	list := build_draw_list(view, frustum, packet.camera.position, cull != nil)
	if cull != nil {
		draws := cull_push_main(cull, list.opaque, frustum)
		p.opaque = draws
		draw_counters_add(&p.counters, draws.counters)
	} else {
		draws, _ := layout_push_runs(layout, list.opaque, nil)
		p.opaque = draws
		draw_counters_add(&p.counters, draws.counters)
		p.draws_visible, p.meshes_culled = list.draws_visible, list.meshes_culled
	}
	transparent := make([dynamic]TransparentDraw, context.temp_allocator)
	// Back to front, one draw per mesh so the order holds. Drawn after everything opaque, skybox
	// included: these don't write depth, so anything drawn later would cover them.
	for item in list.transparent {
		material := pool_get(input.materials, item.mesh.material)
		kind := PipelineKind.Mesh_Transparent_Double_Sided if material.double_sided else PipelineKind.Mesh_Transparent
		draw, ok := layout_push_single(layout, item).(DirectDraw)
		if !ok do break
		append(&transparent, TransparentDraw{kind, draw})
		p.counters.draw_calls += 1
		p.counters.triangles += draw.triangles
	}
	p.transparent = transparent[:]
	p.clear_color, _ = packet.background.(Vec4)
	_, p.sky = packet.background.(TextureHandle)
	p.particles = packet.settings.particles
	if p.sky do p.counters.draw_calls += 1
	if p.particles do p.counters.draw_calls += 1
	return
}

record_main :: proc(r: ^Recorder, p: ^MainPass) {
	// A sky covers every pixel left uncovered, so its clear value never shows.
	encoder := backend.begin_render_pass(
		r.cmd,
		backend.PassConfig {
			color = {image = r.targets.color},
			resolve = {image = r.targets.hdr},
			depth = {image = r.targets.depth},
			clear_color = p.clear_color,
			load_op = .Clear,
		},
	)
	defer backend.end_render_pass(encoder)
	backend.cmd_bind_index_buffer(encoder, r.geometry.index)
	pc := rec_mesh_push_constants(r)
	// Opaque, then the sky (if any) where nothing opaque wrote depth, then transparent on top.
	switch draws in p.opaque {
	case DrawGroups:
		layout_record_groups(r, encoder, draws, &pc)
	case CullDraws:
		cull_record_groups(r, encoder, draws, &pc)
	}
	if p.sky {
		backend.pipeline_bind(encoder, rec_pipeline(r, .Skybox))
		sky_pc := SkyboxPushConstants {
			scene_data = rec_scene_data(r),
		}
		backend.pipeline_push(encoder, &sky_pc)
		backend.cmd_draw(encoder)
		r.tally.draw_calls += 1
	}
	layout_record_transparent(r, encoder, p.transparent)
	if p.particles {
		backend.pipeline_bind(encoder, rec_pipeline(r, .Particle))
		particle_pc := ParticlePushConstants {
			scene_data    = rec_scene_data(r),
			particles_out = backend.buffer_address(r.ctx, r.frame.particle_buffer),
		}
		backend.pipeline_push(encoder, &particle_pc)
		backend.cmd_draw_points(encoder, PARTICLE_COUNT)
		r.tally.draw_calls += 1
	}
	record_lines(r, encoder)
}

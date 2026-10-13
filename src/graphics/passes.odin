package graphics

import "backend"

// The frame, in order. The executor runs each enabled pass inside a GPU timing scope.
PassKind :: enum {
	Particles,
	Shadow_2D,
	Shadow_Point,
	Clusters,
	Main,
	Bloom,
	Tonemap,
	Overlay,
}

// Images that passes hand to each other. Their owners resolve them each frame, so the table
// survives the render targets being recreated on resize.
FrameResource :: enum {
	Msaa_Color,
	Hdr,
	Depth,
	Draw,
	Bloom,
	Shadow_2D,
	Shadow_Cube,
}

FRAME_RESOURCE_ASPECT := [FrameResource]backend.ImageAspectFlags {
	.Msaa_Color  = {.Color},
	.Hdr         = {.Color},
	.Depth       = {.Depth},
	.Draw        = {.Color},
	.Bloom       = {.Color},
	.Shadow_2D   = {.Depth},
	.Shadow_Cube = {.Depth},
}

// The state a frame resource must be in, as a whole image, when the pass starts.
PassUse :: struct {
	resource: FrameResource,
	state:    backend.ImageStateKind,
}

PassSpec :: struct {
	name:   string, // timing scope
	record: proc(r: ^Recorder, f: ^PreparedFrame),
	uses:   []PassUse,
}

PASSES := [PassKind]PassSpec {
	.Particles = {name = "particles", record = record_particles},
	.Shadow_2D = {name = "shadow 2d", record = record_shadow_2d, uses = {{.Shadow_2D, .Depth_Write}}},
	.Shadow_Point = {name = "shadow point", record = record_shadow_point, uses = {{.Shadow_Cube, .Depth_Write}}},
	.Clusters = {name = "clusters", record = record_clusters},
	// Main and Overlay declaring the atlases Depth_Read is what leaves them readable, including
	// when the shadow passes are disabled.
	.Main = {
		name = "main",
		record = record_main,
		uses = {
			{.Msaa_Color, .Color_Write},
			{.Hdr, .Color_Write},
			{.Depth, .Depth_Write},
			{.Shadow_2D, .Depth_Read},
			{.Shadow_Cube, .Depth_Read},
		},
	},
	.Bloom = {name = "bloom", record = record_bloom, uses = {{.Hdr, .Shader_Read}, {.Bloom, .General}}},
	.Tonemap = {
		name = "tonemap",
		record = record_tonemap,
		uses = {{.Hdr, .Shader_Read}, {.Bloom, .Shader_Read}, {.Draw, .General}},
	},
	.Overlay = {
		name = "overlay",
		record = record_overlay,
		uses = {{.Draw, .Color_Write}, {.Shadow_2D, .Depth_Read}, {.Shadow_Cube, .Depth_Read}},
	},
}

frame_resource_image :: proc(r: ^Recorder, resource: FrameResource) -> backend.Image {
	targets := r.targets
	switch resource {
	case .Msaa_Color:
		return targets.color
	case .Hdr:
		return targets.hdr
	case .Depth:
		return targets.depth
	case .Draw:
		return targets.draw
	case .Bloom:
		return targets.bloom
	case .Shadow_2D:
		return r.atlas_2d
	case .Shadow_Cube:
		return r.atlas_cube
	}
	unreachable()
}

// A pass runs when its prepared data is present. Main, Bloom, Tonemap and Overlay always run.
pass_enabled :: proc(f: ^PreparedFrame, kind: PassKind) -> bool {
	switch kind {
	case .Particles:
		return f.passes.particles != nil
	case .Shadow_2D:
		return f.passes.shadow_2d != nil
	case .Shadow_Point:
		return f.passes.shadow_point != nil
	case .Clusters:
		return f.passes.clusters != nil
	case .Main, .Bloom, .Tonemap, .Overlay:
		return true
	}
	unreachable()
}

// Brings each enabled pass's frame resources into its entry states, then records it inside a
// timing scope. The barrier takes each subresource from its tracked state, and skips the ones
// already in a read-only target state.
run_passes :: proc(r: ^Recorder, f: ^PreparedFrame) {
	for spec, kind in PASSES {
		if !pass_enabled(f, kind) do continue
		for use in spec.uses {
			image := frame_resource_image(r, use.resource)
			desc := backend.image_desc(r.ctx, image)
			backend.image_barrier(
				r.cmd,
				image,
				use.state,
				FRAME_RESOURCE_ASPECT[use.resource],
				level_count = desc.mip_levels,
				layer_count = desc.array_layers,
			)
		}
		scope := gpu_scope_begin(r, spec.name)
		spec.record(r, f)
		gpu_scope_end(r, scope)
	}
}

// GPU-culled or CPU-culled draws. Chosen during preparation.
MainOpaque :: union #no_nil {
	DrawGroups,
	CullDraws,
}

// Everything the main pass records, decided during preparation.
MainPrep :: struct {
	opaque:                       MainOpaque,
	transparent:                  []TransparentDraw,
	clear_color:                  Vec4,
	sky, particles:               bool,
	counters:                     DrawCounters,
	draws_visible, meshes_culled: u32,
}

// If GPU culling doesn't fit the budget, falls back to the CPU list, like before.
main_prepare :: proc(input: PrepareInput, layout: ^LayoutBuilder) -> (p: MainPrep, cull: Maybe(CullUpload)) {
	packet := input.packet
	view := DrawInput {
		draws     = draw_history_live(input.history),
		models    = input.models,
		materials = input.materials,
	}
	aspect := extent_aspect(input.targets.extent)
	frustum := frustum_create_from_camera(&packet.camera, aspect)
	list := build_draw_list(view, frustum, packet.camera.position, packet.settings.gpu_cull)
	gpu_culled := false
	if packet.settings.gpu_cull {
		upload, draws, ok := cull_layout_build(list.opaque, frustum, input.budget)
		if ok {
			p.opaque = draws
			cull = upload
			draw_counters_add(&p.counters, draws.counters)
			gpu_culled = true
		} else {
			list = build_draw_list(view, frustum, packet.camera.position)
		}
	}
	if !gpu_culled {
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

@(private = "file")
record_main :: proc(r: ^Recorder, f: ^PreparedFrame) {
	p := &f.passes.main
	if upload, ok := f.uploads.cull.(CullUpload); ok {
		cull_record_dispatch(r, &upload, f.debug.cull_readback)
	}
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

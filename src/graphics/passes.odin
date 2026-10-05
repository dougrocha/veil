package graphics

import "backend"

// The frame, in order. The executor runs each enabled pass inside a GPU timing scope.
PassKind :: enum {
	Particles,
	Shadow_2D,
	Shadow_Point,
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
	name:    string, // timing scope
	enabled: proc(engine: ^Engine) -> bool, // nil = always
	record:  proc(engine: ^Engine, cmd: backend.CommandBuffer),
	uses:    []PassUse,
}

PASSES := [PassKind]PassSpec {
	.Particles = {name = "particles", enabled = particles_enabled, record = dispatch_particles},
	.Shadow_2D = {
		name = "shadow 2d",
		enabled = shadows_enabled,
		record = record_shadow_2d,
		uses = {{.Shadow_2D, .Depth_Write}},
	},
	.Shadow_Point = {
		name = "shadow point",
		enabled = shadows_enabled,
		record = record_shadow_point,
		uses = {{.Shadow_Cube, .Depth_Write}},
	},
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
	.Bloom = {name = "bloom", record = dispatch_bloom, uses = {{.Hdr, .Shader_Read}, {.Bloom, .General}}},
	.Tonemap = {
		name = "tonemap",
		record = dispatch_tonemap,
		uses = {{.Hdr, .Shader_Read}, {.Bloom, .Shader_Read}, {.Draw, .General}},
	},
	.Overlay = {
		name = "overlay",
		record = record_overlay,
		uses = {{.Draw, .Color_Write}, {.Shadow_2D, .Depth_Read}, {.Shadow_Cube, .Depth_Read}},
	},
}

frame_resource_image :: proc(engine: ^Engine, resource: FrameResource) -> backend.Image {
	targets := &engine.render_targets
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
		return engine.shadows.atlas_2d.image
	case .Shadow_Cube:
		return engine.shadows.point_atlas.image
	}
	unreachable()
}

// Brings each enabled pass's frame resources into its entry states, then records it inside a
// timing scope. The barrier takes each subresource from its tracked state, and skips the ones
// already in a read-only target state.
run_passes :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	for spec in PASSES {
		if spec.enabled != nil && !spec.enabled(engine) do continue

		for use in spec.uses {
			image := frame_resource_image(engine, use.resource)
			desc := backend.image_desc(&engine.vk_ctx, image)
			aspect := FRAME_RESOURCE_ASPECT[use.resource]
			backend.image_barrier(
				cmd,
				image,
				use.state,
				aspect,
				level_count = desc.mip_levels,
				layer_count = desc.array_layers,
			)
		}

		scope := gpu_scope_begin(engine, cmd, spec.name)
		spec.record(engine, cmd)
		gpu_scope_end(engine, cmd, scope)
	}
}

@(private = "file")
particles_enabled :: proc(engine: ^Engine) -> bool {
	return engine.debug_settings.particles
}

shadows_enabled :: proc(engine: ^Engine) -> bool {
	return engine.debug_settings.disable_shadows == 0
}

@(private = "file")
record_main :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	encoder := backend.begin_render_pass(
		&engine.vk_ctx,
		cmd,
		backend.PassConfig {
			color = {image = engine.render_targets.color},
			resolve = {image = engine.render_targets.hdr},
			depth = {image = engine.render_targets.depth},
			clear_color = {0.1, 0.1, 0.1, 1},
			load_op = .Clear,
		},
	)
	defer backend.end_render_pass(encoder)
	// Opaque, then the skybox where nothing opaque wrote depth, then transparent on top.
	view_list := view_draw_list(engine)
	draw_meshes_opaque(engine, encoder, view_list)
	draw_skybox(engine, encoder)
	draw_meshes_transparent(engine, encoder, view_list)
	if engine.debug_settings.particles do draw_particles(engine, encoder)
	line_renderer_flush(engine, encoder)
}

@(private = "file")
record_overlay :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	debug_view_flush(engine, cmd)
	encoder := backend.begin_render_pass(
		&engine.vk_ctx,
		cmd,
		backend.PassConfig{color = {image = engine.render_targets.draw}, load_op = .Load},
	)
	defer backend.end_render_pass(encoder)
	draw_ui(engine, encoder)
}

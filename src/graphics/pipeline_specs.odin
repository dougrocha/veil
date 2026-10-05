package graphics

import "backend"

// Which attachments a graphics pipeline is compatible with. Not a render stage: several stages can
// share one layout.
TargetLayout :: enum u8 {
	Main, // MSAA color (resolved into hdr) + depth: meshes, skybox, particles, lines
	Overlay, // draw after the tonemap, no depth: UI, debug view, overlay lines
	Shadow, // depth only, into a shadow atlas layer
}

GraphicsPipelineSpec :: struct {
	shader:   string, // module name in shaders/
	targets:  TargetLayout,
	topology: backend.Topology,
	cull:     backend.CullMode,
	blend:    backend.BlendMode,
	depth:    backend.DepthState,
}

@(rodata)
GRAPHICS_PIPELINES := [GraphicsPipelineKind]GraphicsPipelineSpec {
	.Shadow = {
		shader = "shadow",
		targets = .Shadow,
		cull = .None,
		depth = {test = true, write = true, bias = true, compare = .LessOrEqual},
	},
	// Cascades only cover a slice of the scene along the light direction, so casters between the
	// light and a cascade's near plane would be clipped; depth clamp flattens them onto it instead.
	.Shadow_Directional = {
		shader = "shadow",
		targets = .Shadow,
		cull = .None,
		depth = {test = true, write = true, bias = true, clamp = true, compare = .LessOrEqual},
	},
	.Mesh = {shader = "mesh", targets = .Main, blend = .Alpha, depth = {test = true, write = true, compare = .Less}},
	.Skybox = {shader = "skybox", targets = .Main, cull = .None, depth = {test = true, compare = .LessOrEqual}},
	.UI = {shader = "ui", targets = .Overlay, cull = .None, blend = .Alpha},
	.Particle = {shader = "particle", targets = .Main, topology = .Points, cull = .None, blend = .Alpha},
	.Debug_View = {shader = "debug_view", targets = .Overlay, cull = .None},
	.Debug_Line = {shader = "line", targets = .Main, cull = .None, depth = {test = true, write = true, compare = .Less}},
	// Drawn last, on top of everything: no depth test.
	.Debug_Line_Overlay = {shader = "line", targets = .Main, cull = .None, blend = .Alpha},
	.Debug_Sector = {shader = "sector", targets = .Main, cull = .None, blend = .Alpha},
}

ComputePipelineSpec :: struct {
	shader: string, // module name in shaders/
}

@(rodata)
COMPUTE_PIPELINES := [ComputePipelineKind]ComputePipelineSpec {
	.Particle   = {shader = "particle"},
	.Tonemap    = {shader = "tonemap"},
	.Bloom_Down = {shader = "bloom_down"},
	.Bloom_Up   = {shader = "bloom_up"},
}

// Built from the same format constants the targets are created with, so pipelines don't depend
// on the targets existing.
target_layout :: proc(ctx: ^backend.Context, targets: TargetLayout) -> backend.AttachmentLayout {
	switch targets {
	case .Main:
		return {
			color = {0 = backend.DRAW_FORMAT},
			color_count = 1,
			depth = backend.DEPTH_FORMAT,
			samples = ctx.msaa_samples,
		}
	case .Overlay:
		return {color = {0 = backend.DRAW_FORMAT}, color_count = 1, samples = 1}
	case .Shadow:
		return {depth = SHADOW_DEPTH_FORMAT, samples = 1}
	}
	unreachable()
}

graphics_pipeline_desc :: proc(ctx: ^backend.Context, spec: GraphicsPipelineSpec) -> backend.GraphicsPipelineDesc {
	return {
		attachments = target_layout(ctx, spec.targets),
		topology = spec.topology,
		cull = spec.cull,
		blend = spec.blend,
		depth = spec.depth,
	}
}

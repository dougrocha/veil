package graphics

import "backend"

// Every pipeline the renderer creates. Graphics kinds come first so the zero value of
// PipelineSpec.stage is Graphics.
PipelineKind :: enum u8 {
	Shadow, // spot + point lights
	Shadow_Directional, // directional cascades, one multiview pass per light, depth-clamped
	Mesh, // opaque, no discard
	Mesh_Transparent, // alpha blended, no depth write
	Mesh_Double_Sided, // Mesh without back-face culling
	Mesh_Transparent_Double_Sided,
	// Alpha mask: fragments below the cutoff are discarded. Declared after the opaque kinds, so
	// sorting runs by kind draws every opaque run before any masked one.
	Mesh_Masked,
	Mesh_Masked_Double_Sided,
	Skybox,
	UI,
	Particle, // graphics: particles drawn as points
	Debug_View,
	Debug_Line,
	Debug_Line_Overlay,
	Debug_Sector,
	Particle_Simulate, // compute
	Gpu_Cull, // compute
	Tonemap,
	Bloom_Down,
	Bloom_Up,
	Clusters,
}

PipelineStage :: enum u8 {
	Graphics, // vertex + fragment entry points
	Compute, // compute entry point
}

// Which attachments a graphics pipeline is compatible with. Not a render stage: several stages can
// share one layout.
TargetLayout :: enum u8 {
	Main, // MSAA color (resolved into hdr) + depth: meshes, skybox, particles, lines
	Overlay, // draw after the tonemap, no depth: UI, debug view, overlay lines
	Shadow, // depth only, into a shadow atlas layer
}

PipelineSpec :: struct {
	shader:   string, // module name in shaders/
	fragment: string, // fragment entry point of shader (graphics only); "" means FRAGMENT_MAIN
	stage:    PipelineStage,
	// Graphics only. Ignored by compute pipelines.
	targets:  TargetLayout,
	topology: backend.Topology,
	cull:     backend.CullMode,
	blend:    backend.BlendMode,
	depth:    backend.DepthState,
	views:    u32, // > 1: multiview, drawn in passes with the same PassConfig.view_count
}

@(rodata)
PIPELINE_SPECS := [PipelineKind]PipelineSpec {
	.Shadow = {
		shader = "shadow",
		targets = .Shadow,
		cull = .None,
		depth = {test = true, write = true, bias = true, compare = .LessOrEqual},
	},
	// Cascades only cover a slice of the input along the light direction, so casters between the
	// light and a cascade's near plane would be clipped; depth clamp flattens them onto it instead.
	.Shadow_Directional = {
		shader = "shadow",
		targets = .Shadow,
		cull = .None,
		depth = {test = true, write = true, bias = true, clamp = true, compare = .LessOrEqual},
		views = SHADOW_MAP_CASCADE_COUNT,
	},
	.Mesh = {shader = "mesh", targets = .Main, depth = {test = true, write = true, compare = .Less}},
	.Mesh_Transparent = {shader = "mesh", targets = .Main, blend = .Alpha, depth = {test = true, compare = .Less}},
	.Mesh_Double_Sided = {
		shader = "mesh",
		targets = .Main,
		cull = .None,
		depth = {test = true, write = true, compare = .Less},
	},
	.Mesh_Transparent_Double_Sided = {
		shader = "mesh",
		targets = .Main,
		cull = .None,
		blend = .Alpha,
		depth = {test = true, compare = .Less},
	},
	.Mesh_Masked = {
		shader = "mesh",
		fragment = FRAGMENT_MASKED,
		targets = .Main,
		depth = {test = true, write = true, compare = .Less},
	},
	.Mesh_Masked_Double_Sided = {
		shader = "mesh",
		fragment = FRAGMENT_MASKED,
		targets = .Main,
		cull = .None,
		depth = {test = true, write = true, compare = .Less},
	},
	.Skybox = {shader = "skybox", targets = .Main, cull = .None, depth = {test = true, compare = .LessOrEqual}},
	.UI = {shader = "ui", targets = .Overlay, cull = .None, blend = .Alpha},
	.Particle = {shader = "particle", targets = .Main, topology = .Points, cull = .None, blend = .Alpha},
	.Debug_View = {shader = "debug_view", targets = .Overlay, cull = .None, blend = .Alpha},
	.Debug_Line = {
		shader = "line",
		targets = .Main,
		cull = .None,
		depth = {test = true, write = true, compare = .Less},
	},
	// Drawn last, on top of everything: no depth test.
	.Debug_Line_Overlay = {shader = "line", targets = .Main, cull = .None, blend = .Alpha},
	.Debug_Sector = {shader = "sector", targets = .Main, cull = .None, blend = .Alpha},
	.Particle_Simulate = {shader = "particle", stage = .Compute},
	.Gpu_Cull = {shader = "gpu_cull", stage = .Compute},
	.Tonemap = {shader = "tonemap", stage = .Compute},
	.Bloom_Down = {shader = "bloom_down", stage = .Compute},
	.Bloom_Up = {shader = "bloom_up", stage = .Compute},
	.Clusters = {shader = "clusters", stage = .Compute},
}

// The fragment entry point a graphics spec links: its own, or FRAGMENT_MAIN when unset.
spec_fragment_entry :: proc(spec: PipelineSpec) -> string {
	return spec.fragment if spec.fragment != "" else FRAGMENT_MAIN
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
			samples = backend.limits(ctx).msaa_samples,
		}
	case .Overlay:
		return {color = {0 = backend.DRAW_FORMAT}, color_count = 1, samples = 1}
	case .Shadow:
		return {depth = SHADOW_DEPTH_FORMAT, samples = 1}
	}
	unreachable()
}

graphics_pipeline_desc :: proc(ctx: ^backend.Context, spec: PipelineSpec) -> backend.GraphicsPipelineDesc {
	return {
		attachments = target_layout(ctx, spec.targets),
		topology = spec.topology,
		cull = spec.cull,
		blend = spec.blend,
		depth = spec.depth,
		view_count = spec.views,
	}
}

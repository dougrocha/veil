package graphics

import "backend"

// One struct per pass kind: everything that pass records, decided while building the frame. A pass
// that is skipped this frame is not in the list. The list is in execution order.
Pass :: union {
	ParticlesPass,
	ShadowPass, // one per atlas that has views
	ClustersPass,
	MainPass,
	BloomPass,
	TonemapPass,
	OverlayPass,
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

@(rodata)
USES_SHADOW_2D := [?]PassUse{{.Shadow_2D, .Depth_Write}}
@(rodata)
USES_SHADOW_CUBE := [?]PassUse{{.Shadow_Cube, .Depth_Write}}
// Main and Overlay declaring the atlases Depth_Read is what leaves them readable, including when the
// shadow passes are skipped.
@(rodata)
USES_MAIN := [?]PassUse {
	{.Msaa_Color, .Color_Write},
	{.Hdr, .Color_Write},
	{.Depth, .Depth_Write},
	{.Shadow_2D, .Depth_Read},
	{.Shadow_Cube, .Depth_Read},
}
@(rodata)
USES_BLOOM := [?]PassUse{{.Hdr, .Shader_Read}, {.Bloom, .General}}
@(rodata)
USES_TONEMAP := [?]PassUse{{.Hdr, .Shader_Read}, {.Bloom, .Shader_Read}, {.Draw, .General}}
@(rodata)
USES_OVERLAY := [?]PassUse{{.Draw, .Color_Write}, {.Shadow_2D, .Depth_Read}, {.Shadow_Cube, .Depth_Read}}

// The frame resources a pass touches and the state each must be in before it runs.
pass_uses :: proc(pass: Pass) -> []PassUse {
	switch p in pass {
	case ParticlesPass, ClustersPass:
		return nil
	case ShadowPass:
		return USES_SHADOW_2D[:] if p.atlas == .Atlas_2D else USES_SHADOW_CUBE[:]
	case MainPass:
		return USES_MAIN[:]
	case BloomPass:
		return USES_BLOOM[:]
	case TonemapPass:
		return USES_TONEMAP[:]
	case OverlayPass:
		return USES_OVERLAY[:]
	}
	unreachable()
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

// Brings the pass's frame resources into their entry states, then opens its timing scope; the caller
// closes it with gpu_scope_end. The barrier takes each subresource from its tracked state, and skips
// the ones already in a read-only target state.
@(private = "file")
pass_begin :: proc(r: ^Recorder, name: string, uses: []PassUse) -> int {
	for use in uses {
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
	return gpu_scope_begin(r, name)
}

// Records the list in order. The only place that dispatches on the pass kind, as r_window_submit does.
passes_record :: proc(r: ^Recorder, passes: []Pass) {
	for &pass in passes {
		switch &p in pass {
		case ParticlesPass:
			scope := pass_begin(r, "particles", pass_uses(pass))
			record_particles(r, &p)
			gpu_scope_end(r, scope)
		case ShadowPass:
			scope := pass_begin(r, "shadow 2d" if p.atlas == .Atlas_2D else "shadow point", pass_uses(pass))
			record_shadow(r, &p)
			gpu_scope_end(r, scope)
		case ClustersPass:
			scope := pass_begin(r, "clusters", pass_uses(pass))
			record_clusters(r, &p)
			gpu_scope_end(r, scope)
		case MainPass:
			scope := pass_begin(r, "main", pass_uses(pass))
			record_main(r, &p)
			gpu_scope_end(r, scope)
		case BloomPass:
			scope := pass_begin(r, "bloom", pass_uses(pass))
			record_bloom(r, &p)
			gpu_scope_end(r, scope)
		case TonemapPass:
			scope := pass_begin(r, "tonemap", pass_uses(pass))
			record_tonemap(r, &p)
			gpu_scope_end(r, scope)
		case OverlayPass:
			scope := pass_begin(r, "overlay", pass_uses(pass))
			record_overlay(r, &p)
			gpu_scope_end(r, scope)
		}
	}
}

// The counters record must match, summed from the built passes. The record side keeps its own tally,
// so the two are independent.
passes_counters :: proc(passes: []Pass, plan: ^ShadowPlan) -> FrameCounters {
	counters: FrameCounters
	total: DrawCounters
	for pass in passes {
		switch p in pass {
		case ParticlesPass, ClustersPass, BloomPass, TonemapPass:
		case ShadowPass:
			draw_counters_add(&total, p.counters)
			for v in p.views do counters.shadow_views += v.view.view_count
		case MainPass:
			draw_counters_add(&total, p.counters)
			counters.draws_visible = p.draws_visible
			counters.meshes_culled = p.meshes_culled
		case OverlayPass:
			counters.draw_calls += p.draw_calls
			counters.dropped_lines = p.dropped_lines
			counters.dropped_ui = p.dropped_ui
			counters.dropped_debug_views = p.dropped_debug_views
		}
	}
	counters.draw_calls += total.draw_calls
	counters.indirect_calls = total.indirect_calls
	counters.triangles = total.triangles
	counters.candidate_instances = total.candidate_instances
	counters.candidate_triangles = total.candidate_triangles
	counters.shadow_views_cached = plan.views_cached
	return counters
}

// The first pass of kind T, if the list has one.
pass_find :: proc(passes: []Pass, $T: typeid) -> (^T, bool) {
	for &pass in passes {
		if p, ok := &pass.(T); ok do return p, true
	}
	return nil, false
}

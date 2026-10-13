package graphics

import "backend"
import "core:mem"

// Tested = depth-tested lines, Sector = filled triangles, On_Top = drawn over everything.
LineBatch :: enum {
	Tested,
	Sector,
	On_Top,
}

// Built by game code each tick and borrowed by FramePacket until engine_render returns.
// Storage uses the game temp allocator.
Overlay :: struct {
	lines:       [LineBatch][dynamic]LineVertex,
	ui:          map[u32][dynamic]UIVertex,
	debug_views: [dynamic]DebugViewRequest,
	allocator:   mem.Allocator,
}

PreparedUIBatch :: struct {
	atlas_texture: TextureIndex,
	vertices:      []UIVertex,
}

PreparedDebugView :: struct {
	view: DebugViewPushConstants,
	rect: Rect2D,
	clip: Rect2D,
}

// Clamped to buffer capacities; dropped_* count what didn't fit.
PreparedOverlay :: struct {
	lines:               [LineBatch][]LineVertex,
	ui:                  []PreparedUIBatch,
	debug_views:         []PreparedDebugView,
	draw_calls:          u32,
	dropped_lines:       u32,
	dropped_ui:          u32,
	dropped_debug_views: u32,
}

UploadedLineBatch :: struct {
	vertices: backend.GPUPtr(LineVertex),
	count:    u32,
}

UploadedUIBatch :: struct {
	atlas_texture: TextureIndex,
	vertices:      backend.GPUPtr(UIVertex),
	count:         u32,
}

// This frame's vertices as GPU addresses, read by record_lines and record_overlay.
UploadedOverlay :: struct {
	lines:       [LineBatch]UploadedLineBatch,
	ui:          []UploadedUIBatch,
	debug_views: []PreparedDebugView,
}

// Starts an empty overlay for one tick of game code.
overlay_make :: proc(allocator := context.temp_allocator) -> Overlay {
	o := Overlay {
		allocator = allocator,
	}
	for &batch in o.lines do batch = make([dynamic]LineVertex, allocator)
	o.ui = make(map[u32][dynamic]UIVertex, allocator)
	o.debug_views = make([dynamic]DebugViewRequest, allocator)
	return o
}

// Appends one line segment to the Tested batch, or to On_Top when on_top is set.
overlay_line :: proc(o: ^Overlay, from, to: Vec3, color: Vec4, on_top := false) {
	batch := &o.lines[.On_Top] if on_top else &o.lines[.Tested]
	append(batch, LineVertex{position = from, color = color}, LineVertex{position = to, color = color})
}

// Appends one filled triangle to the Sector batch.
overlay_sector_triangle :: proc(o: ^Overlay, a, b, c: Vec3, color: Vec4) {
	append(
		&o.lines[.Sector],
		LineVertex{position = a, color = color},
		LineVertex{position = b, color = color},
		LineVertex{position = c, color = color},
	)
}

// One batch per font atlas, keyed by the atlas's bindless texture index, so multiple
// fonts/sizes in one frame don't clobber each other's vertices.
overlay_ui_batch :: proc(o: ^Overlay, atlas: u32) -> ^[dynamic]UIVertex {
	if atlas not_in o.ui do o.ui[atlas] = make([dynamic]UIVertex, o.allocator)
	return &o.ui[atlas]
}

// Shows a texture in a screen-space pixel rect for this frame.
// Requests past MAX_DEBUG_VIEWS are dropped.
overlay_texture_view :: proc(o: ^Overlay, texture: TextureHandle, rect: Rect2D) {
	append(&o.debug_views, DebugViewRequest{mode = .Texture_2D, index = u32(texture.index), rect = rect})
}

// Shows a shadow layer in a screen-space pixel rect for this frame.
// Requests past MAX_DEBUG_VIEWS are dropped.
overlay_shadow_view :: proc(o: ^Overlay, mode: DebugViewMode, index, face: u32, rect: Rect2D) {
	append(&o.debug_views, DebugViewRequest{mode = mode, index = index, face = face, rect = rect})
}

// Clamps game geometry to buffer capacities and clips debug views to the target.
// The cluster heatmap view is generated here and always goes last.
overlay_prepare :: proc(o: ^Overlay, settings: RenderSettings, extent: Extent2D) -> PreparedOverlay {
	prepared: PreparedOverlay
	views := make([dynamic]PreparedDebugView, context.temp_allocator)

	if o != nil {
		for batch in LineBatch {
			stride := 3 if batch == .Sector else 2
			count := min(len(o.lines[batch]), MAX_LINE_VERTICES)
			count -= count % stride
			prepared.lines[batch] = o.lines[batch][:count]
			prepared.dropped_lines += u32((len(o.lines[batch]) - count) / stride)
			if count > 0 do prepared.draw_calls += 1
		}
		ui := make([dynamic]PreparedUIBatch, context.temp_allocator)
		for atlas, vertices in o.ui {
			count := min(len(vertices), MAX_UI_VERTICES)
			count -= count % 6
			prepared.dropped_ui += u32((len(vertices) - count) / 6)
			if count == 0 do continue
			append(&ui, PreparedUIBatch{TextureIndex(atlas), vertices[:count]})
			prepared.draw_calls += 1
		}
		prepared.ui = ui[:]

		for req, index in o.debug_views {
			if index >= MAX_DEBUG_VIEWS {
				prepared.dropped_debug_views += 1
				continue
			}
			// Clip to the target; a zero-size or off-screen scissor is invalid.
			x0, y0 := max(i64(req.rect.offset.x), 0), max(i64(req.rect.offset.y), 0)
			x1 := min(i64(req.rect.offset.x) + i64(req.rect.extent.x), i64(extent.width))
			y1 := min(i64(req.rect.offset.y) + i64(req.rect.extent.y), i64(extent.height))
			if x1 <= x0 || y1 <= y0 do continue
			append(
				&views,
				PreparedDebugView {
					view = {mode = req.mode, index = req.index, face = req.face},
					rect = req.rect,
					clip = {offset = {i32(x0), i32(y0)}, extent = {u32(x1 - x0), u32(y1 - y0)}},
				},
			)
		}
	}
	if settings.cluster_heatmap && extent.width > 0 && extent.height > 0 {
		if o != nil && len(o.debug_views) >= MAX_DEBUG_VIEWS {
			prepared.dropped_debug_views += 1
		} else {
			rect := Rect2D {
				extent = {extent.width, extent.height},
			}
			append(&views, PreparedDebugView{view = {mode = .Cluster_Heatmap}, rect = rect, clip = rect})
		}
	}
	prepared.debug_views = views[:]
	prepared.draw_calls += u32(len(views))
	return prepared
}

// Writes this frame's vertices into the per-slot buffers. An atlas's UI buffers are created on first use.
overlay_upload :: proc(
	ctx: ^backend.Context,
	lr: ^LineRenderer,
	ur: ^UIRenderer,
	p: ^PreparedOverlay,
) -> UploadedOverlay {
	uploaded := UploadedOverlay {
		debug_views = p.debug_views,
	}
	slot := backend.frame_slot(ctx)
	for batch in LineBatch {
		vertices := p.lines[batch]
		if len(vertices) == 0 do continue
		buffer := lr.buffers[batch][slot]
		backend.buffer_write(ctx, buffer, vertices)
		uploaded.lines[batch] = {backend.buffer_address(ctx, buffer), u32(len(vertices))}
	}
	ui := make([dynamic]UploadedUIBatch, context.temp_allocator)
	for batch in p.ui {
		atlas := u32(batch.atlas_texture)
		if atlas not_in ur.buffers {
			buffers: [backend.MAX_FRAMES_IN_FLIGHT]backend.Buffer(UIVertex)
			for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
				buffers[i] = backend.buffer_create(UIVertex, ctx, MAX_UI_VERTICES, {.Storage}, .Shared)
			}
			ur.buffers[atlas] = buffers
		}
		buffer := ur.buffers[atlas][slot]
		backend.buffer_write(ctx, buffer, batch.vertices)
		append(
			&ui,
			UploadedUIBatch{batch.atlas_texture, backend.buffer_address(ctx, buffer), u32(len(batch.vertices))},
		)
	}
	uploaded.ui = ui[:]
	return uploaded
}

// Draws each non-empty line batch with its own pipeline.
record_lines :: proc(r: ^Recorder, encoder: backend.RenderEncoder) {
	kinds := [LineBatch]PipelineKind {
		.Tested = .Debug_Line,
		.Sector = .Debug_Sector,
		.On_Top = .Debug_Line_Overlay,
	}
	for batch in LineBatch {
		span := r.overlay.lines[batch]
		if span.count == 0 do continue
		pc := LinePushConstants {
			scene_data    = rec_scene_data(r),
			vertex_buffer = span.vertices,
			screen_size   = {f32(r.targets.extent.width), f32(r.targets.extent.height)},
			thickness     = LINE_THICKNESS_PX,
		}
		backend.pipeline_bind(encoder, rec_pipeline(r, kinds[batch]))
		backend.pipeline_push(encoder, &pc)
		backend.cmd_draw(encoder, span.count * (1 if batch == .Sector else 3))
		r.tally.draw_calls += 1
	}
}

// Draws debug views, then UI, over the tonemapped draw target.
record_overlay :: proc(r: ^Recorder, f: ^PreparedFrame) {
	if len(r.overlay.debug_views) > 0 {
		encoder := backend.begin_render_pass(
			r.cmd,
			backend.PassConfig{color = {image = r.targets.draw}, load_op = .Load},
		)
		backend.pipeline_bind(encoder, rec_pipeline(r, .Debug_View))
		for view in r.overlay.debug_views {
			// Viewport keeps the full rect so a clipped view is cropped, not squashed.
			backend.pipeline_set_viewport(
				encoder,
				f32(view.rect.extent.x),
				f32(view.rect.extent.y),
				f32(view.rect.offset.x),
				f32(view.rect.offset.y),
			)
			backend.pipeline_set_scissor(
				encoder,
				view.clip.extent.x,
				view.clip.extent.y,
				view.clip.offset.x,
				view.clip.offset.y,
			)
			pc := view.view
			pc.scene_data = rec_scene_data(r)
			backend.pipeline_push(encoder, &pc)
			backend.cmd_draw(encoder)
			r.tally.draw_calls += 1
		}
		backend.end_render_pass(encoder)
	}
	if len(r.overlay.ui) == 0 do return
	encoder := backend.begin_render_pass(r.cmd, backend.PassConfig{color = {image = r.targets.draw}, load_op = .Load})
	defer backend.end_render_pass(encoder)
	backend.pipeline_bind(encoder, rec_pipeline(r, .UI))
	for batch in r.overlay.ui {
		pc := UIPushConstants {
			vertex_buffer = batch.vertices,
			screen_size   = {f32(r.targets.extent.width), f32(r.targets.extent.height)},
			atlas_texture = batch.atlas_texture,
		}
		backend.pipeline_push(encoder, &pc)
		backend.cmd_draw(encoder, batch.count)
		r.tally.draw_calls += 1
	}
}

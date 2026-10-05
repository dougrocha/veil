package graphics

import "backend"

MAX_DEBUG_VIEWS :: 64

DebugViewRequest :: struct {
	view: DebugViewPushConstants,
	rect: Rect2D,
}

// Filled during the tick like the UI and line batches, drained every frame.
DebugViewQueue :: struct {
	requests: [MAX_DEBUG_VIEWS]DebugViewRequest,
	count:    int,
}

// Shows a texture, shadow-cube face, or 2D shadow layer in a screen-space pixel rect for this frame.
// Requests past MAX_DEBUG_VIEWS are dropped.
debug_view_draw :: proc(engine: ^Engine, view: DebugViewPushConstants, rect: Rect2D) {
	q := &engine.debug_views
	if q.count >= MAX_DEBUG_VIEWS do return
	q.requests[q.count] = {view, rect}
	q.count += 1
}

debug_view_texture :: proc(engine: ^Engine, texture: TextureHandle, rect: Rect2D) {
	debug_view_draw(engine, {mode = .Texture_2D, index = u32(texture.index)}, rect)
}

debug_view_clear :: proc(engine: ^Engine) {
	engine.debug_views.count = 0
}

// Draws queued views over the resolved frame. Skips the pass entirely when nothing is queued.
debug_view_flush :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	q := &engine.debug_views
	if q.count == 0 do return

	encoder := backend.begin_render_pass(
		&engine.vk_ctx,
		cmd,
		backend.PassConfig{color = {image = engine.render_targets.draw}, load_op = .Load},
	)
	defer backend.end_render_pass(encoder)

	pipeline := get_pipeline(&engine.pipeline_registry, .Debug_View)
	backend.pipeline_bind(encoder, pipeline)

	width := i32(engine.swapchain.extent.width)
	height := i32(engine.swapchain.extent.height)
	for &req in q.requests[:q.count] {
		// Clip to the target; a zero-size or off-screen scissor is invalid.
		x0, y0 := max(req.rect.offset.x, 0), max(req.rect.offset.y, 0)
		x1 := min(req.rect.offset.x + i32(req.rect.extent.x), width)
		y1 := min(req.rect.offset.y + i32(req.rect.extent.y), height)
		if x1 <= x0 || y1 <= y0 do continue

		// Viewport keeps the full rect so a clipped view is cropped, not squashed.
		backend.pipeline_set_viewport(
			encoder,
			f32(req.rect.extent.x),
			f32(req.rect.extent.y),
			f32(req.rect.offset.x),
			f32(req.rect.offset.y),
		)
		backend.pipeline_set_scissor(encoder, u32(x1 - x0), u32(y1 - y0), x0, y0)
		backend.pipeline_push(encoder, pipeline, {.Fragment}, &req.view, index = 1)
		backend.cmd_draw(encoder)
		stats_count_draw(engine)
	}
}

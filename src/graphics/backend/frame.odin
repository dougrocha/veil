package backend

// One frame is frame_begin, record into the returned command buffer, frame_end. The backend owns
// the whole sequence (wait, acquire, submit, present) and the swapchain's lifetime; the caller
// owns its render targets and sizes them to swapchain.extent.

// Waits for this frame's slot, recreates the swapchain if the window size changed or it went
// stale, acquires an image and begins recording. ok = false: nothing to draw into this frame.
frame_begin :: proc(ctx: ^Context, swapchain: ^Swapchain, width, height: u32) -> (cmd: CommandBuffer, ok: bool) {
	// A minimized window has no drawable pixels; keep the old swapchain until it returns.
	if width == 0 || height == 0 do return {}, false

	if swapchain.require_recreate || swapchain.requested != {width, height} {
		device_wait_idle(ctx)
		swapchain_recreate(ctx, swapchain, width, height)
	}

	frame_wait_before_render(ctx)
	frame_sync := current_frame_sync(ctx)

	switch swapchain_acquire_next_image(ctx, swapchain, frame_sync) {
	case .Success:
	case .Suboptimal:
		swapchain.require_recreate = true
	case .OutOfDate:
		swapchain.require_recreate = true
		return {}, false
	case .NotReady:
		return {}, false
	}

	cmd = frame_sync.command_buffer
	cmd_begin_recording(cmd)
	return cmd, true
}

// Copies present into the acquired swapchain image, then ends, submits and presents the frame.
// present must have the swapchain's extent.
frame_end :: proc(ctx: ^Context, swapchain: ^Swapchain, cmd: CommandBuffer, present: Image) {
	present_blit(ctx, cmd, swapchain, present)
	cmd_end_recording(cmd)

	frame_sync := current_frame_sync(ctx)
	queue_submit_frame(ctx, cmd, swapchain, frame_sync)
	switch queue_present_frame(ctx, cmd, swapchain, frame_sync) {
	case .Success:
	case .OutOfDate, .Suboptimal:
		swapchain.require_recreate = true
	}
}

// Which per-frame resource to use for the frame being recorded (0 ..< MAX_FRAMES_IN_FLIGHT).
// Safe to write between frame_begin and frame_end: frame_begin waited for its last user.
frame_slot :: proc(ctx: ^Context) -> int {
	return int(ctx.frame_index % MAX_FRAMES_IN_FLIGHT)
}

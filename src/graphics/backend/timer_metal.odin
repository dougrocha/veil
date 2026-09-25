#+build darwin

package backend

// Not implemented yet: would map to MTLCounterSampleBuffer samples attached at encoder boundaries.
// Every proc reports unsupported so callers skip GPU timing.
GpuTimer :: struct {
	supported: bool,
}

gpu_timer_create :: proc(ctx: ^Context) -> GpuTimer {
	return {}
}

gpu_timer_destroy :: proc(ctx: ^Context, timer: ^GpuTimer) {
}

gpu_timer_read :: proc(ctx: ^Context, timer: ^GpuTimer, slot: u64, out_ms: []f64) -> int {
	return 0
}

gpu_timer_reset :: proc(cmd: CommandBuffer, timer: ^GpuTimer, slot: u64) {
}

gpu_timer_write :: proc(cmd: CommandBuffer, timer: ^GpuTimer, slot: u64) -> (index: u32, ok: bool) {
	return 0, false
}

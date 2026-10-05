package graphics

import "backend"

MAX_GPU_SCOPES :: backend.MAX_GPU_TIMESTAMPS / 2

GpuScope :: struct {
	name:       string, // must outlive the frame; use string literals
	begin, end: u32, // timestamp indices
	ok:         bool,
}

// Named GPU time ranges. Results come back MAX_FRAMES_IN_FLIGHT frames late, when the slot is reused.
GpuProfiler :: struct {
	timer:       backend.GpuTimer,
	scopes:      [backend.MAX_FRAMES_IN_FLIGHT][MAX_GPU_SCOPES]GpuScope,
	scope_count: [backend.MAX_FRAMES_IN_FLIGHT]int,
}

gpu_profiler_create :: proc(engine: ^Engine) {
	engine.gpu_profiler.timer = backend.gpu_timer_create(&engine.vk_ctx)
}

gpu_profiler_destroy :: proc(engine: ^Engine) {
	backend.gpu_timer_destroy(&engine.vk_ctx, &engine.gpu_profiler.timer)
}

// Feeds this slot's previous results into stats. Call after the slot's frame fence wait.
gpu_profiler_collect :: proc(engine: ^Engine) {
	p := &engine.gpu_profiler
	slot := backend.frame_slot(&engine.vk_ctx)
	stamps: [backend.MAX_GPU_TIMESTAMPS]f64
	count := backend.gpu_timer_read(&engine.vk_ctx, &p.timer, slot, stamps[:])
	if count == 0 do return

	for scope in p.scopes[slot][:p.scope_count[slot]] {
		if !scope.ok || int(scope.end) >= count do continue
		stats_add_gpu(engine, scope.name, stamps[scope.end] - stamps[scope.begin])
	}
}

// Starts this slot's recording. Call at the top of the command buffer, outside any pass.
gpu_profiler_reset :: proc(engine: ^Engine, cmd: backend.CommandBuffer) {
	p := &engine.gpu_profiler
	slot := backend.frame_slot(&engine.vk_ctx)
	p.scope_count[slot] = 0
	backend.gpu_timer_reset(cmd, &p.timer, slot)
}

gpu_scope_begin :: proc(engine: ^Engine, cmd: backend.CommandBuffer, name: string) -> int {
	p := &engine.gpu_profiler
	slot := backend.frame_slot(&engine.vk_ctx)
	if p.scope_count[slot] >= MAX_GPU_SCOPES do return -1

	id := p.scope_count[slot]
	p.scope_count[slot] += 1
	begin, ok := backend.gpu_timer_write(cmd, &p.timer, slot)
	p.scopes[slot][id] = {
		name  = name,
		begin = begin,
		ok    = ok,
	}
	return id
}

gpu_scope_end :: proc(engine: ^Engine, cmd: backend.CommandBuffer, id: int) {
	if id < 0 do return
	p := &engine.gpu_profiler
	slot := backend.frame_slot(&engine.vk_ctx)
	scope := &p.scopes[slot][id]
	end, ok := backend.gpu_timer_write(cmd, &p.timer, slot)
	scope.end = end
	scope.ok = scope.ok && ok
}

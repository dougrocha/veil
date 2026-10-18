package graphics

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"

import "backend"

// Timings are averaged over this window so the overlay is readable.
STATS_WINDOW_SECONDS :: 0.5

// Per-frame counts planned before recording and published after submission.
FrameCounters :: struct {
	draw_calls:          u32,
	indirect_calls:      u32,
	triangles:           u64,
	candidate_instances: u32,
	candidate_triangles: u64,
	draws_visible:       u32, // main pass, after frustum culling
	meshes_culled:       u32, // main pass, meshes of visible draws rejected by their AABB
	shadow_views:        u32, // cascade layers + spot maps + cube faces rendered
	shadow_views_cached: u32, // spot maps + cube faces reused from an earlier frame
	dropped_lines:       u32,
	dropped_ui:          u32,
	dropped_debug_views: u32,
}

// Post-cull totals read back from a frame slot's cull commands.
GpuVisible :: struct {
	valid:     bool,
	instances: u64,
	triangles: u64,
}

// CPU milliseconds per engine_render phase.
CpuTimings :: struct {
	frame:  f64, // frame-to-frame, includes the game loop outside engine_render
	wait:   f64, // frame fence + swapchain acquire; high when GPU-bound, or vsync-bound under Fifo (VEIL_PRESENT_MODE)
	record: f64, // input data upload, transforms, command recording
	submit: f64, // queue submit + present
}

// GPU time for one named profiler scope, averaged over the same window as CpuTimings.
GpuScopeStat :: struct {
	name:    string,
	sum:     f64,
	samples: int,
	avg:     f64, // ms, published once per window
}

Stats :: struct {
	latest:       CpuTimings, // raw timings for the most recently submitted frame
	last:         FrameCounters, // last fully recorded frame
	gpu_visible:  GpuVisible, // from an earlier frame: the GPU cull result lands after its fence

	// window accumulators
	sum:          CpuTimings,
	window_min:   f64,
	window_max:   f64,
	window_count: int,
	window_time:  f64,

	// published once per window
	avg:          CpuTimings,
	frame_min:    f64,
	frame_max:    f64,
	fps:          f64,
	gpu:          [MAX_GPU_SCOPES]GpuScopeStat, // in first-seen order
	gpu_count:    int,
	memory:       MemoryStats,
	heap:         ^mem.Tracking_Allocator, // set by stats_track_heap; nil = no heap stats
	heap_prev:    struct {
		count: i64,
		bytes: i64,
	},
}

// Sampled once per frame (last frame's values), not averaged.
MemoryStats :: struct {
	latest:        CpuTimings, // raw timings for the most recently submitted frame
	heap_allocs:   i64, // heap allocations since the previous frame (whole loop, game + engine)
	heap_bytes:    i64,
	heap_live:     i64, // bytes currently allocated on the tracked heap
	arena_used:    uint, // engine frame arena (temp allocator) at the end of the frame
	arena_peak:    uint,
	system_arenas: uint, // backend, texture, material, model and shader arenas; invisible to the tracked heap
	vram_used:     u64, // device-local heaps, VMA estimate
	vram_budget:   u64,
}

// Reads heap stats from the app's tracking allocator. The engine only reads it.
stats_track_heap :: proc(engine: ^Engine, tracker: ^mem.Tracking_Allocator) {
	engine.stats.heap = tracker
	engine.stats.heap_prev = {tracker.total_allocation_count, tracker.total_memory_allocated}
}

// Call at the end of engine_render, before the frame arena is freed.
stats_memory_sample :: proc(engine: ^Engine) {
	m := &engine.stats.memory
	if t := engine.stats.heap; t != nil {
		prev := &engine.stats.heap_prev
		m.heap_allocs = t.total_allocation_count - prev.count
		m.heap_bytes = t.total_memory_allocated - prev.bytes
		m.heap_live = t.current_memory_allocated
		prev^ = {t.total_allocation_count, t.total_memory_allocated}
	}
	m.arena_used = engine.frame_arena.total_used
	m.arena_peak = max(m.arena_peak, m.arena_used)
	m.system_arenas =
		engine.vk_ctx.arena.total_used +
		engine.texture_system.arena.total_used +
		engine.material_system.arena.total_used +
		engine.model_system.arena.total_used +
		engine.shader_system.arena.total_used
	m.vram_used, m.vram_budget = backend.memory_budget(&engine.vk_ctx)
}

stats_add_timings :: proc(engine: ^Engine, t: CpuTimings) {
	s := &engine.stats
	s.latest = t
	if s.window_count == 0 {
		s.window_min = t.frame
		s.window_max = t.frame
	}
	s.sum.frame += t.frame
	s.sum.wait += t.wait
	s.sum.record += t.record
	s.sum.submit += t.submit
	s.window_min = min(s.window_min, t.frame)
	s.window_max = max(s.window_max, t.frame)
	s.window_count += 1
	s.window_time += t.frame / 1000

	if s.window_time < STATS_WINDOW_SECONDS do return
	n := f64(s.window_count)
	s.avg = {s.sum.frame / n, s.sum.wait / n, s.sum.record / n, s.sum.submit / n}
	s.frame_min = s.window_min
	s.frame_max = s.window_max
	s.fps = n / s.window_time
	for &g in s.gpu[:s.gpu_count] {
		// a scope that stopped being recorded (e.g. particles toggled off) drops to 0
		g.avg = g.sum / f64(g.samples) if g.samples > 0 else 0
		g.sum = 0
		g.samples = 0
	}
	s.sum = {}
	s.window_count = 0
	s.window_time = 0
}

stats_add_gpu :: proc(engine: ^Engine, name: string, ms: f64) {
	s := &engine.stats
	for &g in s.gpu[:s.gpu_count] {
		if g.name == name {
			g.sum += ms
			g.samples += 1
			return
		}
	}
	if s.gpu_count >= len(s.gpu) do return
	s.gpu[s.gpu_count] = {
		name    = name,
		sum     = ms,
		samples = 1,
	}
	s.gpu_count += 1
}

tick_ms :: proc(start: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(start))
}

// Queues the stats panel as UI text at (x, y), one line per `line_height` pixels, followed by the
// caller's extra lines.
stats_draw :: proc(
	engine: ^Engine,
	overlay: ^Overlay,
	font: ^Baked_Font,
	x, y, line_height: f32,
	extra: []string = nil,
) {
	s := &engine.stats
	c := &s.last
	draw_line := fmt.tprintf(
		"draws %d  indirect calls %d  tris %.2fM  visible %d  meshes culled %d  shadow views %d (%d cached)",
		c.draw_calls,
		c.indirect_calls,
		f64(c.triangles) / 1e6,
		c.draws_visible,
		c.meshes_culled,
		c.shadow_views,
		c.shadow_views_cached,
	)
	if c.candidate_instances > 0 {
		visibility := "GPU visibility unknown"
		if s.gpu_visible.valid {
			visibility = fmt.tprintf(
				"visible %d (gpu, latent) / %.2fM tris",
				s.gpu_visible.instances,
				f64(s.gpu_visible.triangles) / 1e6,
			)
		}
		draw_line = fmt.tprintf(
			"draws %d  indirect calls %d  %s  candidates %d / %.2fM tris  shadow views %d (%d cached)",
			c.draw_calls,
			c.indirect_calls,
			visibility,
			c.candidate_instances,
			f64(c.candidate_triangles) / 1e6,
			c.shadow_views,
			c.shadow_views_cached,
		)
	}
	lines := [?]string {
		fmt.tprintf("%.0f fps  %.2f ms  (min %.2f  max %.2f)", s.fps, s.avg.frame, s.frame_min, s.frame_max),
		fmt.tprintf(
			"cpu  wait %.2f  record %.2f  submit %.2f  other %.2f",
			s.avg.wait,
			s.avg.record,
			s.avg.submit,
			max(s.avg.frame - s.avg.wait - s.avg.record - s.avg.submit, 0),
		),
		draw_line,
	}
	gpu_line := "gpu  timestamps unsupported"
	if s.gpu_count > 0 {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "gpu")
		for g in s.gpu[:s.gpu_count] do fmt.sbprintf(&b, "  %s %.2f", g.name, g.avg)
		gpu_line = strings.to_string(b)
	}

	m := &s.memory
	heap_line := "heap untracked"
	if s.heap != nil {
		heap_line = fmt.tprintf(
			"heap %d allocs %s/frame (%s live)",
			m.heap_allocs,
			fmt_bytes(m.heap_bytes),
			fmt_bytes(m.heap_live),
		)
	}
	mem_line := fmt.tprintf(
		"mem  %s  arena %s (peak %s)  sys arenas %s  vram %s / %s est.",
		heap_line,
		fmt_bytes(i64(m.arena_used)),
		fmt_bytes(i64(m.arena_peak)),
		fmt_bytes(i64(m.system_arenas)),
		fmt_bytes(i64(m.vram_used)),
		fmt_bytes(i64(m.vram_budget)),
	)

	all_lines := make([dynamic]string, context.temp_allocator)
	append(&all_lines, lines[0], lines[1], gpu_line, lines[2], mem_line)
	if c.dropped_lines > 0 || c.dropped_ui > 0 || c.dropped_debug_views > 0 {
		append(
			&all_lines,
			fmt.tprintf(
				"overlay dropped %d lines  %d glyphs  %d views",
				c.dropped_lines,
				c.dropped_ui,
				c.dropped_debug_views,
			),
		)
	}
	append(&all_lines, ..extra)
	for line, i in all_lines {
		ly := y + f32(i) * line_height
		// drop shadow keeps it readable over bright and dark scenes
		overlay_text(overlay, font, line, x + 1, ly + 1, {0, 0, 0, 255})
		overlay_text(overlay, font, line, x, ly, {255, 255, 255, 255})
	}
}

@(private = "file")
fmt_bytes :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 30:
		return fmt.tprintf("%.2f GB", f64(n) / (1 << 30))
	case n >= 1 << 20:
		return fmt.tprintf("%.1f MB", f64(n) / (1 << 20))
	case n >= 1 << 10:
		return fmt.tprintf("%.1f KB", f64(n) / (1 << 10))
	}
	return fmt.tprintf("%d B", n)
}

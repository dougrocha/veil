package backend

import "core:log"

import vk "vendor:vulkan"

// One query pool per frame slot, so a slot's results are read only after its fence has passed.
GpuTimer :: struct {
	pools:      [MAX_FRAMES_IN_FLIGHT]vk.QueryPool,
	written:    [MAX_FRAMES_IN_FLIGHT]u32, // timestamps recorded into each slot's last submission
	period_ns:  f64,
	valid_mask: u64,
	supported:  bool,
}

gpu_timer_create :: proc(ctx: ^Context) -> (timer: GpuTimer) {
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(ctx.physical_device, &props)

	fam_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(ctx.physical_device, &fam_count, nil)
	fams := make([]vk.QueueFamilyProperties, fam_count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(ctx.physical_device, &fam_count, raw_data(fams))
	valid_bits := fams[ctx.gfx_queue_fam_idx].timestampValidBits

	if valid_bits == 0 || props.limits.timestampPeriod == 0 {
		log.warnf("GPU timestamps unsupported on the graphics queue")
		return
	}

	timer.period_ns = f64(props.limits.timestampPeriod)
	timer.valid_mask = max(u64) if valid_bits >= 64 else (u64(1) << valid_bits) - 1
	for &pool in timer.pools {
		info := vk.QueryPoolCreateInfo {
			sType      = .QUERY_POOL_CREATE_INFO,
			queryType  = .TIMESTAMP,
			queryCount = MAX_GPU_TIMESTAMPS,
		}
		vk_check(vk.CreateQueryPool(ctx.device, &info, nil, &pool))
	}
	timer.supported = true
	return
}

gpu_timer_destroy :: proc(ctx: ^Context, timer: ^GpuTimer) {
	for pool in timer.pools {
		if pool != 0 do vk.DestroyQueryPool(ctx.device, pool, nil)
	}
	timer^ = {}
}

// Reads the slot's previous submission as milliseconds on the GPU clock. Call after the slot's
// frame fence has been waited on. Returns 0 when there is nothing to read.
gpu_timer_read :: proc(ctx: ^Context, timer: ^GpuTimer, slot: int, out_ms: []f64) -> int {
	count := min(int(timer.written[slot]), len(out_ms))
	if !timer.supported || count == 0 do return 0

	ticks: [MAX_GPU_TIMESTAMPS]u64
	result := vk.GetQueryPoolResults(
		ctx.device,
		timer.pools[slot],
		0,
		u32(count),
		size_of(u64) * count,
		&ticks,
		size_of(u64),
		{._64},
	)
	if result != .SUCCESS do return 0

	for i in 0 ..< count {
		out_ms[i] = f64(ticks[i] & timer.valid_mask) * timer.period_ns / 1e6
	}
	return count
}

// Resets the slot's queries at the start of its command buffer.
gpu_timer_reset :: proc(cmd: CommandBuffer, timer: ^GpuTimer, slot: int) {
	timer.written[slot] = 0
	if !timer.supported do return
	vk.CmdResetQueryPool(cmd.handle, timer.pools[slot], 0, MAX_GPU_TIMESTAMPS)
}

// Writes a timestamp once all prior work completes. Returns false when out of queries or unsupported.
gpu_timer_write :: proc(cmd: CommandBuffer, timer: ^GpuTimer, slot: int) -> (index: u32, ok: bool) {
	if !timer.supported || timer.written[slot] >= MAX_GPU_TIMESTAMPS do return 0, false
	index = timer.written[slot]
	vk.CmdWriteTimestamp2(cmd.handle, {.ALL_COMMANDS}, timer.pools[slot], index)
	timer.written[slot] += 1
	return index, true
}

package graphics

import "core:mem"

import "backend"

// CPU items filled during a tick, copied to the current frame slot's buffer at draw time.
TransientBatch :: struct($T: typeid) {
	items:   [dynamic]T,
	buffers: [backend.MAX_FRAMES_IN_FLIGHT]backend.Buffer(T),
}

transient_batch_create :: proc(ctx: ^backend.Context, b: ^TransientBatch($T), capacity: int) {
	for i in 0 ..< backend.MAX_FRAMES_IN_FLIGHT {
		b.buffers[i] = backend.buffer_create(T, ctx, capacity, {.Storage}, .Shared)
	}
	reserve(&b.items, capacity)
}

transient_batch_destroy :: proc(ctx: ^backend.Context, b: ^TransientBatch($T)) {
	delete(b.items)
	for buffer in b.buffers do backend.buffer_destroy(ctx, buffer)
}

// Drops this tick's items. Called from engine_render's defer, not only on drawn frames: batches
// are filled every tick, so a skipped frame must still drain them or they overflow.
transient_batch_clear :: proc(b: ^TransientBatch($T)) {
	clear(&b.items)
}

// Copies items into the current slot's buffer. count is 0 (and nothing is copied) when empty.
transient_batch_upload :: proc(ctx: ^backend.Context, b: ^TransientBatch($T)) -> (ptr: backend.GPUPtr(T), count: u32) {
	if len(b.items) == 0 do return

	buffer := b.buffers[backend.frame_slot(ctx)]
	assert(len(b.items) * size_of(T) <= backend.buffer_desc(ctx, buffer).size)
	mem.copy(backend.buffer_contents(ctx, buffer), raw_data(b.items), len(b.items) * size_of(T))
	return backend.buffer_address(ctx, buffer), u32(len(b.items))
}

#+private
package backend

import vk "vendor:vulkan"

// Vulkan objects whose handle is already freed but which the GPU may still be using.
Releasable :: union {
	ImageSlot,
	BufferSlot,
	ShaderSlot,
}

PendingRelease :: struct {
	retire_value: u64, // timeline value after which the GPU no longer touches the resource
	resource:     Releasable,
}

// Queues the resource for release once the frame being recorded completes. That frame
// signals frame_index + 1 and every earlier submit signals less, so this covers all
// work that could reference it.
release_deferred :: proc(ctx: ^Context, resource: Releasable) {
	append(&ctx.pending_releases, PendingRelease{retire_value = ctx.frame_index + 1, resource = resource})
}

// Releases everything the GPU has finished with.
release_completed :: proc(ctx: ^Context) {
	completed: u64
	vk_check(vk.GetSemaphoreCounterValue(ctx.device, ctx.timeline_semaphore, &completed))
	release_up_to(ctx, completed)
}

// Releases everything regardless of the timeline. Only after device_wait_idle.
release_all :: proc(ctx: ^Context) {
	release_up_to(ctx, max(u64))
}

@(private = "file")
release_up_to :: proc(ctx: ^Context, value: u64) {
	// frame_index only grows, so retire values are in order and the done entries are a prefix.
	done := 0
	for pending in ctx.pending_releases {
		if pending.retire_value > value do break
		switch resource in pending.resource {
		case ImageSlot:
			image_slot_release(ctx, resource)
		case BufferSlot:
			buffer_slot_release(ctx, resource)
		case ShaderSlot:
			shader_slot_release(ctx, resource)
		}
		done += 1
	}
	remove_range(&ctx.pending_releases, 0, done)
}

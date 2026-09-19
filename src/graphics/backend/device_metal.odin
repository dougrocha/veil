#+build darwin

package backend

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"
import sdl "vendor:sdl3"

context_init :: proc(ctx: ^Context, window: ^sdl.Window) -> bool {
	ctx.device = MTL.CreateSystemDefaultDevice()
	if ctx.device == nil {
		return false
	}

	ctx.command_queue = ctx.device->newCommandQueue()
	if ctx.command_queue == nil {
		return false
	}

	ctx.metal_view = sdl.Metal_CreateView(window)
		ctx.layer = (^CA.MetalLayer)(sdl.Metal_GetLayer(ctx.metal_view))
		ctx.layer->setDevice(ctx.device)
		ctx.layer->setPixelFormat(.BGRA8Unorm)
		// This renderer resolves into an offscreen target and blits it into the
		// drawable. SDL's layer defaults to framebuffer-only textures, which cannot
		// be blit destinations.
		ctx.layer->setFramebufferOnly(false)

	width, height: i32
	sdl.GetWindowSizeInPixels(window, &width, &height)
	ctx.layer->setDrawableSize(NS.Size{NS.Float(width), NS.Float(height)})

	ctx.max_bindless_samplers_per_stage = u32(ctx.device->maxArgumentBufferSamplerCount())

	ctx.msaa_samples = 1
	candidate_samples := [4]u32{8, 4, 2, 1}
	for count in candidate_samples {
		if ctx.device->supportsTextureSampleCount(NS.UInteger(count)) {
			ctx.msaa_samples = count
			break
		}
	}

	return true
}

context_destroy :: proc(ctx: ^Context) {
	sdl.Metal_DestroyView(ctx.metal_view)
}

device_wait_idle :: proc(ctx: ^Context) {
	for &sync in ctx.frame_sync {
		if sync.command_buffer != nil {
			sync.command_buffer->waitUntilCompleted()
		}
	}
}

// Objective-C methods that don't start with new/alloc/copy hand back autoreleased
// objects (command buffers, encoders, drawables, descriptors from class helpers).
// Without a pool on the stack they pile up until the thread's outermost pool drains,
// which for our SDL main loop is never. Every scope that talks to Metal in bulk
// brackets itself with these.
autorelease_pool_begin :: proc() -> rawptr {
	return NS.AutoreleasePool_alloc()->init()
}

autorelease_pool_end :: proc(pool: rawptr) {
	(^NS.AutoreleasePool)(pool)->drain()
}

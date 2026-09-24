#+build darwin

package backend

import "core:log"

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

AcquireImageResult :: enum {
	Success,
	OutOfDate,
	Suboptimal,
	// No image this frame, but nothing is stale: skip the frame and try again.
	// Not a reason to rebuild anything.
	NotReady,
}

PresentFrameResult :: enum {
	Success,
	OutOfDate,
	Suboptimal,
	Error,
}

FrameSync :: struct {
	command_buffer: ^MTL.CommandBuffer,
}

frame_sync_create :: proc(ctx: ^Context) {
}

upload_pool_create :: proc(ctx: ^Context) {
}

frame_sync_destroy :: proc(ctx: ^Context) {
	for &sync in ctx.frame_sync {
		if sync.command_buffer == nil do continue
		sync.command_buffer->waitUntilCompleted()
		sync.command_buffer->release()
		sync.command_buffer = nil
	}
}

current_frame_sync :: proc(ctx: ^Context, frame_index: u64) -> ^FrameSync {
	return &ctx.frame_sync[frame_index % MAX_FRAMES_IN_FLIGHT]
}

frame_command_buffer_begin :: proc(ctx: ^Context, frame_sync: ^FrameSync) -> CommandBuffer {
	cmd := ctx.command_queue->commandBuffer()
	return CommandBuffer(cmd)
}

frame_wait_before_render :: proc(ctx: ^Context, frame_index: u64) {
	frame_sync := current_frame_sync(ctx, frame_index)
	if frame_sync.command_buffer != nil {
		frame_sync.command_buffer->waitUntilCompleted()
		if frame_sync.command_buffer->status() == .Error {
			err := frame_sync.command_buffer->error()
			if err != nil {
				log.errorf("Metal command buffer failed: %s", err->localizedDescription()->odinString())
			}
		}
		frame_sync.command_buffer->release()
		frame_sync.command_buffer = nil
	}
}

queue_submit_frame :: proc(
	ctx: ^Context,
	cmd: CommandBuffer,
	swapchain: ^Swapchain,
	frame_sync: ^FrameSync,
	signal_value: u64,
) {
	mtl_cmd := (^MTL.CommandBuffer)(cmd)
	mtl_cmd->retain()
	frame_sync.command_buffer = mtl_cmd
}

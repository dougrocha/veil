package main

import "core:fmt"
import gfx "veil:graphics"

// Which post value the arrow keys adjust.
PostControl :: enum {
	Exposure,
	Bloom_Strength,
	Bloom_Levels,
}

EXPOSURE_STEP :: 0.25
BLOOM_STRENGTH_STEP :: 0.05

// Left/Right: selects the next or previous post value (dir = +1 / -1), wrapping around.
post_control_cycle :: proc(control: ^PostControl, dir: int) {
	n := len(PostControl)
	control^ = PostControl((int(control^) + dir + n) % n)
}

// Up/Down: steps the selected post value (dir = +1 / -1), clamped to its valid range.
post_control_step :: proc(post: ^gfx.PostSettings, control: PostControl, dir: int) {
	switch control {
	case .Exposure:
		post.exposure = max(post.exposure + f32(dir) * EXPOSURE_STEP, 0)
	case .Bloom_Strength:
		post.bloom_strength = max(post.bloom_strength + f32(dir) * BLOOM_STRENGTH_STEP, 0)
	case .Bloom_Levels:
		post.bloom_max_levels = u32(clamp(int(post.bloom_max_levels) + dir, 1, gfx.BLOOM_MAX_MIPS))
	}
}

// Stats line for the post values; ">" marks the one the arrow keys adjust. Levels shows the
// setting and what actually runs after the resolution clamp.
post_control_line :: proc(engine: ^gfx.Engine, post: gfx.PostSettings, control: PostControl) -> string {
	mark :: proc(selected, c: PostControl) -> string {
		return ">" if selected == c else " "
	}
	return fmt.tprintf(
		"post %sexposure %.2f  %sbloom %.2f  %slevels %d/%d",
		mark(control, .Exposure),
		post.exposure,
		mark(control, .Bloom_Strength),
		post.bloom_strength,
		mark(control, .Bloom_Levels),
		post.bloom_max_levels,
		gfx.bloom_levels(engine, post.bloom_max_levels),
	)
}

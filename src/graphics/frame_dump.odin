package graphics

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"

import stbi "vendor:stb/image"

import "backend"

// Set VEIL_DUMP_FRAME to a frame count to write that many frames out as PNGs
// and exit, or to a path prefix + count ("out/frame:3"). Exists so a headless
// run can be inspected without a window or a screenshot.
FrameDump :: struct {
	enabled:   bool,
	remaining: int,
	prefix:    string,
}

// Debug switches that a headless dump run needs but has no keyboard for.
debug_env_init :: proc(engine: ^Engine) {
	if value, found := os.lookup_env("VEIL_PARTICLES", context.allocator); found {
		defer delete(value)
		engine.debug_settings.particles = value != "0"
		log.infof("particles enabled via VEIL_PARTICLES: %v", engine.debug_settings.particles)
	}

	if value, found := os.lookup_env("VEIL_NO_SHADOWS", context.allocator); found {
		defer delete(value)
		if value != "0" {
			engine.debug_settings.disable_shadows = 1
			log.infof("shadows disabled via VEIL_NO_SHADOWS")
		}
	}

	if value, found := os.lookup_env("VEIL_LIGHTS", context.allocator); found {
		defer delete(value)
		mask: u32
		for name in strings.split(value, ",", context.temp_allocator) {
			switch strings.to_lower(strings.trim_space(name), context.temp_allocator) {
			case "point":
				mask |= u32(LightMask.Point)
			case "dir", "directional", "sun":
				mask |= u32(LightMask.Directional)
			case "spot":
				mask |= u32(LightMask.Spot)
			case "all":
				mask |= LIGHT_MASK_ALL
			case "none":
			case:
				log.warnf("VEIL_LIGHTS: unknown light type %q", name)
			}
		}
		engine.debug_settings.light_mask = mask
		log.infof("light mask set via VEIL_LIGHTS=%s -> 0b%b", value, mask)
	}

	if value, found := os.lookup_env("VEIL_CASCADES", context.allocator); found {
		defer delete(value)
		if value != "0" {
			engine.debug_settings.show_cascades = 1
			log.infof("cascade debug colors enabled via VEIL_CASCADES")
		}
	}
}

// VEIL_PICK_TEST="x,y" runs pick() once at that pixel and logs the hit, so the
// unprojection can be checked headlessly instead of by clicking.
pick_test_run :: proc(engine: ^Engine) {
	value, found := os.lookup_env("VEIL_PICK_TEST", context.allocator)
	if !found do return
	defer delete(value)

	parts := strings.split(value, ",", context.temp_allocator)
	if len(parts) != 2 {
		log.errorf("VEIL_PICK_TEST expects \"x,y\", got %q", value)
		return
	}
	x, x_ok := strconv.parse_f32(strings.trim_space(parts[0]))
	y, y_ok := strconv.parse_f32(strings.trim_space(parts[1]))
	if !x_ok || !y_ok {
		log.errorf("VEIL_PICK_TEST could not parse %q", value)
		return
	}

	hit := pick(engine, Vec2{x, y})
	if hit == INVALID_INSTANCE {
		log.infof("pick test (%v, %v) -> MISS", x, y)
		return
	}
	instance := instance_get(engine, hit)
	model := pool_get(&engine.model_system.models, instance.model)
	log.infof(
		"pick test (%v, %v) -> instance %v (%s) at %v",
		x,
		y,
		hit.index,
		model.name,
		instance.transform.translation,
	)
}

frame_dump_init :: proc(engine: ^Engine) {
	value, found := os.lookup_env("VEIL_DUMP_FRAME", context.allocator)
	if !found do return
	defer delete(value)

	fd := &engine.frame_dump
	fd.prefix = "frame"
	count_text := value

	if colon := strings.last_index_byte(value, ':'); colon >= 0 {
		fd.prefix = strings.clone(value[:colon])
		count_text = value[colon + 1:]
	} else {
		fd.prefix = strings.clone(fd.prefix)
	}

	count, ok := strconv.parse_int(strings.trim_space(count_text))
	if !ok || count <= 0 do count = 1

	fd.enabled = true
	fd.remaining = count
	log.infof("frame dump enabled: %d frame(s) to %s_NNN.png", count, fd.prefix)
}

frame_dump_destroy :: proc(engine: ^Engine) {
	delete(engine.frame_dump.prefix)
}

// Called once per frame after the draw target holds the finished image.
// Returns true when the requested frames have been written and the app
// should quit.
frame_dump_capture :: proc(engine: ^Engine) -> (done: bool) {
	fd := &engine.frame_dump
	if !fd.enabled || fd.remaining <= 0 do return false

	target := &engine.render_targets.draw
	pixels := backend.image_read_rgba8(&engine.vk_ctx, target)
	defer delete(pixels)

	index := int(engine.frame_index)
	path := fmt.tprintf("%s_%03d.png", fd.prefix, index)
	path_cstr := strings.clone_to_cstring(path, context.temp_allocator)

	width := i32(engine.swapchain.extent.width)
	height := i32(engine.swapchain.extent.height)
	// Drop alpha: the draw target's alpha is a blending artifact, not something a
	// screenshot should carry.
	rgb := make([]u8, int(width) * int(height) * 3, context.temp_allocator)
	for i in 0 ..< int(width) * int(height) {
		rgb[i * 3 + 0] = pixels[i * 4 + 0]
		rgb[i * 3 + 1] = pixels[i * 4 + 1]
		rgb[i * 3 + 2] = pixels[i * 4 + 2]
	}

	if stbi.write_png(path_cstr, width, height, 3, raw_data(rgb), width * 3) == 0 {
		log.errorf("frame dump: could not write %s", path)
	} else {
		log.infof("frame dump: wrote %s (%dx%d)", path, width, height)
	}

	fd.remaining -= 1
	return fd.remaining <= 0
}

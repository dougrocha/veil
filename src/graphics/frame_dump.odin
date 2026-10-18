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
	if value, found := os.lookup_env("VEIL_GPU_CULL_VALIDATE", context.temp_allocator); found {
		engine.gpu_cull_validate = value == "1"
		if engine.gpu_cull_validate do log.infof("GPU culling validation enabled")
	}

	when ODIN_DEBUG {
		if value, found := os.lookup_env("VEIL_CLUSTER_VALIDATE", context.temp_allocator); found {
			engine.cluster_validate = value != "0"
			log.infof("cluster validation enabled: %v", engine.cluster_validate)
		}
	}

	// For profiling: Fifo caps fps at the refresh rate and puts the vsync wait into frame times.
	if value, found := os.lookup_env("VEIL_PRESENT_MODE", context.temp_allocator); found {
		switch strings.to_lower(strings.trim_space(value), context.temp_allocator) {
		case "fifo":
			engine.config.present_mode = .Fifo
		case "mailbox":
			engine.config.present_mode = .Mailbox
		case "immediate":
			engine.config.present_mode = .Immediate
		case:
			log.warnf("VEIL_PRESENT_MODE: unknown mode %q (fifo, mailbox, immediate), using fifo", value)
		}
		log.infof("present mode requested via VEIL_PRESENT_MODE: %v", engine.config.present_mode)
	}
}

// Applies the VEIL_* render switches to the game's settings, for headless runs with no keyboard.
render_settings_from_env :: proc(settings: ^RenderSettings) {
	if value, found := os.lookup_env("VEIL_GPU_CULL", context.temp_allocator); found {
		settings.gpu_cull = value != "0"
		log.infof("GPU frustum culling: %v", settings.gpu_cull)
	}

	if value, found := os.lookup_env("VEIL_CLUSTERED", context.temp_allocator); found {
		settings.clustered_lighting = value != "0"
		log.infof("clustered lighting enabled via VEIL_CLUSTERED: %v", settings.clustered_lighting)
	}

	if value, found := os.lookup_env("VEIL_CLUSTER_HEATMAP", context.temp_allocator); found {
		settings.cluster_heatmap = value != "0"
		log.infof("cluster heatmap enabled: %v", settings.cluster_heatmap)
	}

	if value, found := os.lookup_env("VEIL_PARTICLES", context.temp_allocator); found {
		settings.particles = value != "0"
		log.infof("particles enabled via VEIL_PARTICLES: %v", settings.particles)
	}

	if value, found := os.lookup_env("VEIL_NO_SHADOWS", context.temp_allocator); found {
		if value != "0" {
			settings.shadows = false
			log.infof("shadows disabled via VEIL_NO_SHADOWS")
		}
	}

	if value, found := os.lookup_env("VEIL_LIGHTS", context.temp_allocator); found {
		lights: LightTypes
		for name in strings.split(value, ",", context.temp_allocator) {
			switch strings.to_lower(strings.trim_space(name), context.temp_allocator) {
			case "point":
				lights += {.Point}
			case "dir", "directional", "sun":
				lights += {.Directional}
			case "spot":
				lights += {.Spot}
			case "all":
				lights = LIGHT_TYPES_ALL
			case "none":
			case:
				log.warnf("VEIL_LIGHTS: unknown light type %q", name)
			}
		}
		settings.lights = lights
		log.infof("lights set via VEIL_LIGHTS=%s -> %v", value, lights)
	}

	if value, found := os.lookup_env("VEIL_CASCADES", context.temp_allocator); found {
		if value != "0" {
			settings.cascade_colors = true
			log.infof("cascade debug colors enabled via VEIL_CASCADES")
		}
	}
}

// VEIL_PICK_TEST="x,y" runs pick() once at that pixel and logs the hit, so the
// unprojection can be checked headlessly instead of by clicking.
pick_test_run :: proc(engine: ^Engine, packet: ^FramePacket) {
	value, found := os.lookup_env("VEIL_PICK_TEST", context.temp_allocator)
	if !found do return

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

	id, hit := pick(engine, packet.camera, Vec2{x, y})
	if !hit {
		log.infof("pick test (%v, %v) -> MISS", x, y)
		return
	}
	record := engine.prev_draws.records[id]
	model := pool_get(&engine.model_system.models, record.model)
	log.infof("pick test (%v, %v) -> draw %v (%s) at %v", x, y, id, model.name, matrix_translation(record.world))
}

frame_dump_init :: proc(engine: ^Engine) {
	value, found := os.lookup_env("VEIL_DUMP_FRAME", context.temp_allocator)
	if !found do return

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

	pixels := backend.image_read_rgba8(&engine.vk_ctx, engine.render_targets.draw)
	defer delete(pixels)

	index := int(engine.frame_count) - 1 // the frame just submitted
	path := fmt.tprintf("%s_%03d.png", fd.prefix, index)
	path_cstr := strings.clone_to_cstring(path, context.temp_allocator)

	width := i32(render_extent(engine).width)
	height := i32(render_extent(engine).height)
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

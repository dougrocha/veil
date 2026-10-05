package graphics

import "core:log"
import "core:os"
import "core:strings"

import "backend"

import stbtt "vendor:stb/truetype"

FONT_ATLAS_SIZE :: 512
FONT_FIRST_CHAR :: 32 // ' '
FONT_NUM_CHARS :: 95 // ASCII 32..126, printable range

// Well-known sans-serif TTFs, checked in order, first hit wins. No bundled
// fallback asset — if none of these exist, the caller gets `ok = false`.
when ODIN_OS == .Linux {
	DEFAULT_SYSTEM_FONT_CANDIDATES :: []string {
		"/usr/share/fonts/TTF/DejaVuSans.ttf",
		"/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
		"/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
	}
} else when ODIN_OS == .Darwin {
	DEFAULT_SYSTEM_FONT_CANDIDATES :: []string {
		"/System/Library/Fonts/Supplemental/Arial.ttf",
		"/System/Library/Fonts/Helvetica.ttc",
	}
} else {
	DEFAULT_SYSTEM_FONT_CANDIDATES :: []string{}
}

Baked_Font :: struct {
	texture:      TextureHandle,
	path:         string, // registration key in the texture system's linear_texture_map
	chardata:     [FONT_NUM_CHARS]stbtt.bakedchar,
	atlas_w:      i32,
	atlas_h:      i32,
	first_char:   i32,
	num_chars:    i32,
	pixel_height: f32,
}

font_destroy :: proc(engine: ^Engine, font: ^Baked_Font) {
	texture_unload(engine, &engine.texture_system.linear_texture_map, font.path)
	delete(font.path)
	font.path = ""
}

// Loads the first available well-known system sans-serif font — for UI text
// that doesn't need a specific bundled typeface. Returns ok = false if none
// of DEFAULT_SYSTEM_FONT_CANDIDATES exist on this machine.
font_load_default_system :: proc(engine: ^Engine, pixel_height: f32) -> (font: Baked_Font, ok: bool) {
	// Prefer whatever the OS reports as its UI font; the candidate list is only
	// a fallback for platforms with no query wired up (or if it fails).
	if sys_path, sys_ok := system_ui_font_path(context.temp_allocator); sys_ok {
		if os.exists(sys_path) {
			if font, ok = font_load_from_file(engine, sys_path, pixel_height); ok {
				return font, true
			}
			log.warnf("system UI font '%s' could not be baked, falling back", sys_path)
		}
	}

	for path in DEFAULT_SYSTEM_FONT_CANDIDATES {
		if os.exists(path) {
			return font_load_from_file(engine, path, pixel_height)
		}
	}
	log.errorf("No default system font found (checked %d candidate paths)", len(DEFAULT_SYSTEM_FONT_CANDIDATES))
	return {}, false
}

font_load_from_file :: proc(engine: ^Engine, path: string, pixel_height: f32) -> (font: Baked_Font, ok: bool) {
	ttf_data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil {
		log.errorf("Failed to read font file '%s': %v", path, read_err)
		return {}, false
	}
	defer delete(ttf_data)

	atlas_pixels := make([]byte, FONT_ATLAS_SIZE * FONT_ATLAS_SIZE)
	defer delete(atlas_pixels)

	font.path = strings.clone(path)
	font.atlas_w = FONT_ATLAS_SIZE
	font.atlas_h = FONT_ATLAS_SIZE
	font.first_char = FONT_FIRST_CHAR
	font.num_chars = FONT_NUM_CHARS
	font.pixel_height = pixel_height

	result := stbtt.BakeFontBitmap(
		raw_data(ttf_data),
		0,
		pixel_height,
		raw_data(atlas_pixels),
		font.atlas_w,
		font.atlas_h,
		font.first_char,
		font.num_chars,
		raw_data(font.chardata[:]),
	)
	if result <= 0 {
		log.errorf("Failed to bake font atlas for '%s' (fit: %d of %d chars)", path, -result, font.num_chars)
		delete(font.path)
		return {}, false
	}

	texture := Texture {
		extent        = backend.extent3d(u32(font.atlas_w), u32(font.atlas_h), 1),
		channel_count = 1,
	}
	texture_upload(&engine.vk_ctx, raw_data(atlas_pixels), &texture, .R8_Unorm)

	ts := &engine.texture_system
	font.texture = texture_register(engine, &ts.linear_texture_map, path, texture)

	log.debugf(
		"Loaded font: %s (%dx%d atlas, %d glyphs baked) -> bindless slot %d",
		path,
		font.atlas_w,
		font.atlas_h,
		font.num_chars,
		font.texture.index,
	)

	return font, true
}

// Appends `text`'s glyph quads to the engine's UI text batch, in screen-pixel
// space (top-left origin, y-down — matches stb_truetype's baked-quad convention).
ui_draw_text :: proc(engine: ^Engine, font: ^Baked_Font, text: string, x, y: f32, color: [4]u8) {
	batch := ui_renderer_batch_for(engine, u32(font.texture.index))

	xpos, ypos := x, y
	for r in text {
		char_index := i32(r) - font.first_char
		if char_index < 0 || char_index >= font.num_chars {
			continue
		}

		quad: stbtt.aligned_quad
		// false selects D3D/Vulkan-style pixel-center convention (vs. OpenGL's), matching this renderer's backend.
		stbtt.GetBakedQuad(
			raw_data(font.chardata[:]),
			font.atlas_w,
			font.atlas_h,
			char_index,
			&xpos,
			&ypos,
			&quad,
			false,
		)

		top_left := UI_Vertex {
			position = {quad.x0, quad.y0},
			uv       = {quad.s0, quad.t0},
			color    = color,
		}
		top_right := UI_Vertex {
			position = {quad.x1, quad.y0},
			uv       = {quad.s1, quad.t0},
			color    = color,
		}
		bottom_left := UI_Vertex {
			position = {quad.x0, quad.y1},
			uv       = {quad.s0, quad.t1},
			color    = color,
		}
		bottom_right := UI_Vertex {
			position = {quad.x1, quad.y1},
			uv       = {quad.s1, quad.t1},
			color    = color,
		}

		append(&batch.items, top_left, top_right, bottom_right, top_left, bottom_right, bottom_left)
	}
}

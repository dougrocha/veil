#+build darwin

package graphics

import "core:strings"

// Asks CoreText for whatever the OS currently uses as its UI font (SF Pro on
// modern macOS) and resolves it to a file path stb_truetype can read, instead of
// guessing at well-known paths. Returns ok = false if the lookup fails, and the
// caller falls back to DEFAULT_SYSTEM_FONT_CANDIDATES.
//
// SFNS.ttf is a variable font; stb_truetype ignores the variation axes and bakes
// the default instance, which is the regular weight.

foreign import core_text "system:CoreText.framework"
foreign import core_foundation "system:CoreFoundation.framework"

@(private = "file")
CTFontUIFontType :: enum u32 {
	System = 2, // kCTFontUIFontSystem
}

@(private = "file")
foreign core_text {
	CTFontCreateUIFontForLanguage :: proc "c" (uiType: CTFontUIFontType, size: f64, language: rawptr) -> rawptr ---
	CTFontCopyAttribute :: proc "c" (font: rawptr, attribute: rawptr) -> rawptr ---
	kCTFontURLAttribute: rawptr
}

@(private = "file")
foreign core_foundation {
	CFRelease :: proc "c" (cf: rawptr) ---
	CFURLGetFileSystemRepresentation :: proc "c" (url: rawptr, resolveAgainstBase: b8, buffer: [^]u8, maxBufLen: int) -> b8 ---
}

system_ui_font_path :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	font := CTFontCreateUIFontForLanguage(.System, 0, nil)
	if font == nil do return "", false
	defer CFRelease(font)

	url := CTFontCopyAttribute(font, kCTFontURLAttribute)
	if url == nil do return "", false
	defer CFRelease(url)

	buffer: [4096]u8
	if !CFURLGetFileSystemRepresentation(url, true, raw_data(buffer[:]), len(buffer)) {
		return "", false
	}

	return strings.clone_from_cstring(cstring(raw_data(buffer[:])), allocator), true
}

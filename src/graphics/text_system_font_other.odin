#+build !darwin

package graphics

// No OS query wired up outside macOS yet; font_load_default_system falls back to
// DEFAULT_SYSTEM_FONT_CANDIDATES. Linux would go through fontconfig
// (FcFontMatch on "sans-serif") to get the equivalent.
system_ui_font_path :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	return "", false
}

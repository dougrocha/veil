package backend

TextureFilter :: enum {
	Linear,
	Nearest,
}

TextureRepeat :: enum {
	Repeat,
	Mirrored_Repeat,
	Clamp_To_Edge,
	Clamp_To_Border,
}

TextureFormat :: enum {
	Undefined,
	Rgba8_Unorm_Srgb,
	Rgba8_Unorm,
	D32_Sfloat,
	R8_Unorm,
}

#+build darwin

package backend

import MTL "vendor:darwin/Metal"

texture_repeat_to_backend :: proc(repeat: TextureRepeat) -> MTL.SamplerAddressMode {
	switch repeat {
	case .Repeat:
		return .Repeat
	case .Mirrored_Repeat:
		return .MirrorRepeat
	case .Clamp_To_Edge:
		return .ClampToEdge
	case .Clamp_To_Border:
		return .ClampToBorderColor
	}
	return .Repeat
}

texture_format_to_backend :: proc(format: TextureFormat) -> MTL.PixelFormat {
	switch format {
	case .Undefined:
		return .Invalid
	case .Rgba8_Unorm_Srgb:
		return .RGBA8Unorm_sRGB
	case .Rgba8_Unorm:
		return .RGBA8Unorm
	case .D32_Sfloat:
		return .Depth32Float
	case .R8_Unorm:
		return .R8Unorm
	}
	return .RGBA8Unorm_sRGB
}

pixel_format_bytes_per_pixel :: proc(format: MTL.PixelFormat) -> u32 {
	#partial switch format {
	case .R8Unorm, .R8Unorm_sRGB:
		return 1
	case .RG8Unorm, .RG8Unorm_sRGB:
		return 2
	case .RGBA8Unorm, .RGBA8Unorm_sRGB, .BGRA8Unorm, .BGRA8Unorm_sRGB:
		return 4
	}
	return 4
}

channel_count_to_format :: proc(channels: u8, srgb: bool = true) -> MTL.PixelFormat {
	switch channels {
	case 1:
		return .R8Unorm_sRGB if srgb else .R8Unorm
	case 2:
		return .RG8Unorm_sRGB if srgb else .RG8Unorm
	case 4:
		return .RGBA8Unorm_sRGB if srgb else .RGBA8Unorm
	}
	return .RGBA8Unorm_sRGB
}

texture_filter_to_backend :: proc(filter: TextureFilter) -> MTL.SamplerMinMagFilter {
	switch filter {
	case .Nearest:
		return .Nearest
	case .Linear:
		return .Linear
	}
	return .Nearest
}

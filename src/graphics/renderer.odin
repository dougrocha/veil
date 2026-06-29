package graphics

import "core:log"
import vk "vendor:vulkan"

TextureType :: enum {
	UNKNOWN,
	DIFFUSE,
	SPECULAR,
	NORMAL,
}

TextureFilter :: enum {
	LINEAR,
	NEAREST,
}

TextureRepeat :: enum {
	REPEAT,
	MIRRORED_REPEAT,
	CLAMP_TO_EDGE,
	CLAMP_TO_BORDER,
}

// TODO: add more but this all we support for now
TextureFormat :: enum {
	R8G8B8A8_SRGB,
	R8G8B8A8_UNORM,
}

texture_repeat_to_vk :: proc(repeat: TextureRepeat) -> vk.SamplerAddressMode {
	switch repeat {
	case .REPEAT:
		return .REPEAT
	case .MIRRORED_REPEAT:
		return .MIRRORED_REPEAT
	case .CLAMP_TO_EDGE:
		return .CLAMP_TO_EDGE
	case .CLAMP_TO_BORDER:
		return .CLAMP_TO_BORDER
	case:
		log.warn("cannot convert %s, default: REPEAT", repeat)
	}
	return .REPEAT
}

texture_format_to_vk :: proc(format: TextureFormat) -> vk.Format {
	switch format {
	case .R8G8B8A8_SRGB:
		return .R8G8B8A8_SRGB
	case .R8G8B8A8_UNORM:
		return .R8G8B8A8_UNORM
	case:
		log.warn("cannot convert %v, default: R8G8B8A8_SRGB", format)
	}
	return .R8G8B8A8_SRGB
}

channel_count_to_format :: proc(channels: u8, srgb: bool = true) -> vk.Format {
	switch channels {
	case 1:
		return .R8_SRGB if srgb else .R8_UNORM
	case 2:
		return .R8G8_SRGB if srgb else .R8G8_UNORM
	case 4:
		return .R8G8B8A8_SRGB if srgb else .R8G8B8A8_UNORM
	}
	return .R8G8B8A8_SRGB
}

texture_filter_to_vk :: proc(filter: TextureFilter) -> vk.Filter {
	switch filter {
	case .NEAREST:
		return vk.Filter.NEAREST
	case .LINEAR:
		return vk.Filter.LINEAR
	case:
		log.warnf("cannot handle %v", filter)
		return vk.Filter.NEAREST
	}
}

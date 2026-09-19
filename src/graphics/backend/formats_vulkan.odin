#+build linux

package backend

import "core:log"

import vk "vendor:vulkan"

texture_repeat_to_backend :: proc(repeat: TextureRepeat) -> vk.SamplerAddressMode {
	switch repeat {
	case .Repeat:
		return .REPEAT
	case .Mirrored_Repeat:
		return .MIRRORED_REPEAT
	case .Clamp_To_Edge:
		return .CLAMP_TO_EDGE
	case .Clamp_To_Border:
		return .CLAMP_TO_BORDER
	case:
		log.warn("cannot convert %s, default: REPEAT", repeat)
	}
	return .REPEAT
}

texture_format_to_backend :: proc(format: TextureFormat) -> vk.Format {
	switch format {
	case .Undefined:
		return .UNDEFINED
	case .Rgba8_Unorm_Srgb:
		return .R8G8B8A8_SRGB
	case .Rgba8_Unorm:
		return .R8G8B8A8_UNORM
	case .D32_Sfloat:
		return .D32_SFLOAT
	case .R8_Unorm:
		return .R8_UNORM
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

texture_filter_to_backend :: proc(filter: TextureFilter) -> vk.Filter {
	switch filter {
	case .Nearest:
		return vk.Filter.NEAREST
	case .Linear:
		return vk.Filter.LINEAR
	case:
		log.warnf("cannot handle %v", filter)
		return vk.Filter.NEAREST
	}
}

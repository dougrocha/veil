package backend

import "core:log"

import vk "vendor:vulkan"

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

// Backend-neutral pixel format for every image: textures, render targets, depth.
Format :: enum {
	Undefined,
	Rgba8_Unorm_Srgb,
	Rgba8_Unorm,
	Rgba16_Sfloat,
	D32_Sfloat,
	R8_Unorm,
}

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

format_to_vk :: proc(format: Format) -> vk.Format {
	switch format {
	case .Undefined:
		return .UNDEFINED
	case .Rgba8_Unorm_Srgb:
		return .R8G8B8A8_SRGB
	case .Rgba8_Unorm:
		return .R8G8B8A8_UNORM
	case .Rgba16_Sfloat:
		return .R16G16B16A16_SFLOAT
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

// Sample counts are plain numbers (1, 2, 4, ...) outside the backend.
samples_to_vk :: proc(count: u32) -> vk.SampleCountFlags {
	switch count {
	case 64:
		return {._64}
	case 32:
		return {._32}
	case 16:
		return {._16}
	case 8:
		return {._8}
	case 4:
		return {._4}
	case 2:
		return {._2}
	}
	return {._1}
}

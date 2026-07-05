package backend

import "core:log"

import vk "vendor:vulkan"

vk_check :: #force_inline proc(result: vk.Result, message := "Vulkan Error", loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("[Vulkan Failure] %s: %v", message, result, loc)
	}
}

vk_get_physical_device_properties :: proc(ctx: ^VulkanContext) -> vk.PhysicalDeviceProperties {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(ctx.physical_device, &properties)
	return properties
}

vk_get_physical_device_format_properties :: proc(ctx: ^VulkanContext, format: vk.Format) -> vk.FormatProperties {
	format_props: vk.FormatProperties
	vk.GetPhysicalDeviceFormatProperties(ctx.physical_device, format, &format_props)
	return format_props
}

format_aspect_mask :: proc(format: vk.Format) -> vk.ImageAspectFlags {
	// TODO: handle more
	#partial switch format {
	case .D32_SFLOAT, .D16_UNORM:
		return {.DEPTH}
	case .D32_SFLOAT_S8_UINT, .D24_UNORM_S8_UINT:
		return {.DEPTH, .STENCIL}
	case:
		return {.COLOR}
	}
}

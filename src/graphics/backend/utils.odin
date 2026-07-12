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

vk_get_max_bindless_samplers_per_stage :: proc(ctx: ^VulkanContext) -> u32 {
	descriptor_indexing_props := vk.PhysicalDeviceDescriptorIndexingProperties {
		sType = .PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_PROPERTIES,
	}
	props2 := vk.PhysicalDeviceProperties2 {
		sType = .PHYSICAL_DEVICE_PROPERTIES_2,
		pNext = &descriptor_indexing_props,
	}
	vk.GetPhysicalDeviceProperties2(ctx.physical_device, &props2)

	properties := vk_get_physical_device_properties(ctx)

	return descriptor_indexing_props.maxPerStageDescriptorUpdateAfterBindSamplers
}

vk_get_max_usable_sample_count :: proc(ctx: ^VulkanContext) -> vk.SampleCountFlags {
	properties := vk_get_physical_device_properties(ctx)
	counts := properties.limits.framebufferColorSampleCounts & properties.limits.framebufferDepthSampleCounts

	if ._64 in counts {return {._64}}
	if ._32 in counts {return {._32}}
	if ._16 in counts {return {._16}}
	if ._8 in counts {return {._8}}
	if ._4 in counts {return {._4}}
	if ._2 in counts {return {._2}}
	return {._1}
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

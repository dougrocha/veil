package graphics

import "base:runtime"

import "core:log"

import vma "shared:odin-vma"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

VALIDATION_LAYER_NAME :: "VK_LAYER_KHRONOS_validation"

create_vulkan_instance :: proc(ctx: ^VulkanContext) {
	vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))
	assert(vk.CreateInstance != nil, "vulkan function pointers not loaded")

	app_info := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "First Triangle",
		apiVersion       = vk.API_VERSION_1_4,
		pEngineName      = "Veil",
	}

	extension_count: u32 = 0
	sdl_extensions := sdl.Vulkan_GetInstanceExtensions(&extension_count)
	extensions := make([dynamic]cstring, context.temp_allocator)
	append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	for i in 0 ..< int(extension_count) {
		append(&extensions, sdl_extensions[i])
	}

	requested_layers := []cstring{VALIDATION_LAYER_NAME}

	dbg_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.VERBOSE, .INFO, .WARNING, .ERROR},
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = vk_messenger_callback,
	}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pNext                   = &dbg_create_info,
		pApplicationInfo        = &app_info,
		enabledLayerCount       = u32(len(requested_layers)),
		ppEnabledLayerNames     = raw_data(requested_layers),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}

	vk_check(vk.CreateInstance(&create_info, nil, &ctx.instance))

	vk.load_proc_addresses_instance(ctx.instance)
}

create_vulkan_surface :: proc(app: ^App) -> (vk.SurfaceKHR, bool) {
	surface: vk.SurfaceKHR
	if !sdl.Vulkan_CreateSurface(app.window, app.engine.vk_ctx.instance, nil, &surface) {
		log.errorf("Failed to create vulkan surface: %s", sdl.GetError())
		return {}, false
	}
	return surface, true
}

find_physical_device :: proc(self: ^VulkanContext) -> (vk.PhysicalDevice, bool) {
	device_count: u32 = 0
	vk.EnumeratePhysicalDevices(self.instance, &device_count, nil)
	if device_count == 0 {
		log.errorf("No Vulkan physical devices found")
		return nil, false
	}

	physical_devices := make([]vk.PhysicalDevice, device_count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(self.instance, &device_count, raw_data(physical_devices))

	physical_device := physical_devices[0]
	for device in physical_devices {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)
		if props.deviceType == .DISCRETE_GPU {
			physical_device = device
			break
		}
	}

	format_count: u32 = 0
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, self.surface, &format_count, nil)
	surface_formats := make([]vk.SurfaceFormatKHR, format_count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, self.surface, &format_count, raw_data(surface_formats))

	format_supported := false
	for surface_format in surface_formats {
		if surface_format.format == SWAPCHAIN_FORMAT {
			format_supported = true
			break
		}
	}

	if !format_supported {
		log.errorf("Requested swapchain format is not supported by surface")
		return nil, false
	}

	return physical_device, true
}

find_graphics_queue :: proc(ctx: ^VulkanContext) -> bool {
	queue_fam_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties2(ctx.physical_device, &queue_fam_count, nil)
	queue_fam_props := make([]vk.QueueFamilyProperties2, queue_fam_count, context.temp_allocator)
	for &p in queue_fam_props {p.sType = .QUEUE_FAMILY_PROPERTIES_2}
	vk.GetPhysicalDeviceQueueFamilyProperties2(ctx.physical_device, &queue_fam_count, raw_data(queue_fam_props))

	for i in 0 ..< queue_fam_count {
		has_present_support: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(ctx.physical_device, i, ctx.surface, &has_present_support)

		props := queue_fam_props[i]
		if .GRAPHICS in props.queueFamilyProperties.queueFlags &&
		   .COMPUTE in props.queueFamilyProperties.queueFlags &&
		   has_present_support {
			ctx.gfx_queue_fam_idx = i
			return true
		}
	}

	log.errorf("Unable to find a graphics queue")
	return false
}

create_logical_device :: proc(ctx: ^VulkanContext) -> bool {
	features_14 := vk.PhysicalDeviceVulkan14Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
	}
	features_13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext = &features_14,
	}
	features_12 := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &features_13,
	}
	features_11 := vk.PhysicalDeviceVulkan11Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext = &features_12,
	}
	supported_features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &features_11,
	}
	vk.GetPhysicalDeviceFeatures2(ctx.physical_device, &supported_features)

	if !features_13.dynamicRendering ||
	   !features_13.synchronization2 ||
	   !features_12.timelineSemaphore ||
	   !features_12.bufferDeviceAddress ||
	   !features_12.scalarBlockLayout ||
	   !features_12.descriptorBindingPartiallyBound ||
	   !features_12.runtimeDescriptorArray ||
	   !features_12.descriptorBindingSampledImageUpdateAfterBind ||
	   !features_11.shaderDrawParameters ||
	   !supported_features.features.samplerAnisotropy ||
	   !supported_features.features.sampleRateShading {
		log.errorf("Physical Device does not meet feature requirement")
		return false
	}

	enabled_features_14 := vk.PhysicalDeviceVulkan14Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
	}
	enabled_features_13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = &enabled_features_14,
		dynamicRendering = true,
		synchronization2 = true,
	}
	enabled_features_12 := vk.PhysicalDeviceVulkan12Features {
		sType                                        = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext                                        = &enabled_features_13,
		timelineSemaphore                            = true,
		bufferDeviceAddress                          = true,
		scalarBlockLayout                            = true,
		descriptorBindingPartiallyBound              = true,
		runtimeDescriptorArray                       = true,
		descriptorBindingSampledImageUpdateAfterBind = true,
	}
	enabled_features_11 := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext                = &enabled_features_12,
		shaderDrawParameters = true,
	}
	enabled_features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &enabled_features_11,
		features = {samplerAnisotropy = true, sampleRateShading = true, imageCubeArray = true},
	}

	queue_priorities := []f32{1.0}
	gfx_queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = ctx.gfx_queue_fam_idx,
		queueCount       = 1,
		pQueuePriorities = raw_data(queue_priorities),
	}

	device_extensions := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

	dev_create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &enabled_features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &gfx_queue_info,
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
		pEnabledFeatures        = nil,
	}

	vk_check(vk.CreateDevice(ctx.physical_device, &dev_create_info, nil, &ctx.device))

	vk.load_proc_addresses_device(ctx.device)
	vk.GetDeviceQueue(ctx.device, ctx.gfx_queue_fam_idx, 0, &ctx.graphics_queue)
	if ctx.graphics_queue == nil {
		log.errorf("Could not get graphics queue")
		return false
	}

	return true
}

initialize_vma :: proc(ctx: ^VulkanContext) {
	vulkan_functions := vma.create_vulkan_functions()

	create_info := vma.Allocator_Create_Info {
		flags              = {.Buffer_Device_Address},
		instance           = ctx.instance,
		physical_device    = ctx.physical_device,
		device             = ctx.device,
		vulkan_api_version = vk.API_VERSION_1_4,
		vulkan_functions   = &vulkan_functions,
	}

	vk_check(vma.create_allocator(create_info, &ctx.vma_allocator))
}

vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = g_ctx

	level: log.Level
	if .ERROR in messageSeverity {
		runtime.debug_trap()
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}


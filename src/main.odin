package main

import "base:runtime"
import "core:log"
import "core:time"

import sp "shared:odin-slang/slang"
import vma "shared:odin-vma"
import sdl "vendor:sdl3"
import vk "vendor:vulkan"

SWAPCHAIN_FORMAT :: vk.Format.B8G8R8A8_SRGB
DEPTH_FORMAT :: vk.Format.D32_SFLOAT
MAX_FRAMES_IN_FLIGHT :: 2

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

Mat4x4 :: matrix[4, 4]f32
Mat4x3 :: matrix[4, 3]f32

Vertex :: struct {
	pos:   Vec2,
	color: Vec3,
}

UniformBufferObject :: struct #align (16) {
	model: Mat4x4,
	view:  Mat4x4,
	proj:  Mat4x4,
}

vertex_binding_description :: proc() -> vk.VertexInputBindingDescription {
	return {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
}

vertex_attribute_descriptions :: proc() -> [2]vk.VertexInputAttributeDescription {
	return {
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
		{location = 1, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, color))},
	}
}

g_ctx: runtime.Context

FrameResources :: struct {
	command_pool:             vk.CommandPool,
	command_buffer:           vk.CommandBuffer,
	image_acquired_semaphore: vk.Semaphore,
}

App :: struct {
	window: ^sdl.Window,
	width:  u32,
	height: u32,
	engine: Engine,
}

Engine :: struct {
	// core
	instance:                   vk.Instance,
	surface:                    vk.SurfaceKHR,
	physical_device:            vk.PhysicalDevice,
	device:                     vk.Device,
	vma_allocator:              vma.Allocator,

	// queue
	gfx_queue_fam_idx:          u32,
	graphics_queue:             vk.Queue,

	// swapchain
	swapchain:                  vk.SwapchainKHR,
	swapchain_images:           []vk.Image,
	swapchain_image_view:       []vk.ImageView,
	render_complete_semaphores: []vk.Semaphore,
	require_swapchain_recreate: bool,
	swapchain_width:            u32,
	swapchain_height:           u32,
	depth_image:                vk.Image,
	depth_image_view:           vk.ImageView,
	depth_image_allocation:     vma.Allocation,

	// shaders
	slang_session:              ^sp.IGlobalSession,
	shader_module:              vk.ShaderModule,

	// graphics pipeline
	pipeline:                   vk.Pipeline,
	pipeline_layout:            vk.PipelineLayout,
	descriptor_pool:            vk.DescriptorPool,
	descriptor_set_layout:      vk.DescriptorSetLayout,
	descriptor_sets:            [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSet,

	// frame and sync resources
	timeline_semaphore:         vk.Semaphore,
	frame_resources:            [MAX_FRAMES_IN_FLIGHT]FrameResources,
	frame_index:                u64,
	next_signal_value:          u64,

	// buffers
	vertices:                   []Vertex,
	indices:                    []u16,
	geometry_buffer:            vk.Buffer,
	geometry_buffer_allocation: vma.Allocation,
	index_buffer_offset:        vk.DeviceSize,

	// uniform buffers (one per frame in flight)
	uniform_buffers:            [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	uniform_buffer_allocations: [MAX_FRAMES_IN_FLIGHT]vma.Allocation,
	uniform_buffers_mapped:     [MAX_FRAMES_IN_FLIGHT]rawptr,

	// timers
	start_time:                 time.Time,
}

main :: proc() {
	context.logger = log.create_console_logger()
	g_ctx = context

	ok := sdl.InitSubSystem({.VIDEO})
	if !ok {
		log.errorf("Failed to init")
		return
	}
	defer sdl.Quit()


	app := App {
		width  = 1280,
		height = 720,
	}

	app.window = sdl.CreateWindow("odin-vulkan", i32(app.width), i32(app.height), {.RESIZABLE, .VULKAN})
	if app.window == nil {
		log.errorf("Failed to create window: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(app.window)

	if !initialize_vulkan(&app) {
		log.errorf("Failed to initialize Vulkan")
		return
	}
	defer engine_shutdown(&app.engine)

	main_loop: for {
		ev: sdl.Event

		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				if ev.key.key == sdl.K_ESCAPE {
					break main_loop
				}
			case .WINDOW_PIXEL_SIZE_CHANGED:
				app.width = u32(ev.window.data1)
				app.height = u32(ev.window.data2)
				app.engine.require_swapchain_recreate = true
			}
		}

		engine_render(&app)
	}
}


engine_shutdown :: proc(self: ^Engine) {
	// wait in case resources are still in use
	vk.DeviceWaitIdle(self.device)

	// buffers
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vma.destroy_buffer(self.vma_allocator, self.uniform_buffers[i], self.uniform_buffer_allocations[i])
	}
	vma.destroy_buffer(self.vma_allocator, self.geometry_buffer, self.geometry_buffer_allocation)

	// descriptors
	vk.DestroyDescriptorPool(self.device, self.descriptor_pool, nil)
	vk.DestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, nil)

	// pipeline
	vk.DestroyPipeline(self.device, self.pipeline, nil)
	vk.DestroyPipelineLayout(self.device, self.pipeline_layout, nil)

	// cleanup shaders
	vk.DestroyShaderModule(self.device, self.shader_module, nil)
	slang_cleanup(self)

	// frame and sync object cleanup
	vk.DestroySemaphore(self.device, self.timeline_semaphore, nil)
	for &res in self.frame_resources {
		vk.DestroySemaphore(self.device, res.image_acquired_semaphore, nil)
		vk.DestroyCommandPool(self.device, res.command_pool, nil)
	}
	cleanup_swapchain(self)
	vma.destroy_allocator(self.vma_allocator)

	vk.DestroyDevice(self.device, nil)
	vk.DestroySurfaceKHR(self.instance, self.surface, nil)
	vk.DestroyInstance(self.instance, nil)
}

initialize_vulkan :: proc(app: ^App) -> bool {
	self := &app.engine

	self.start_time = time.now()

	create_vulkan_instance(self)

	if !create_vulkan_surface(app) {
		log.errorf("Could not create a vulkan surface")
		return false
	}

	if self.physical_device = find_physical_device(self); self.physical_device == nil {
		log.errorf("Could not find a physical device")
		return false
	}

	if !find_graphics_queue(self) {
		log.errorf("Unable to find a graphics queue")
		return false
	}

	if !create_logical_device(self) {
		log.errorf("Cannot create logical device")
		return false
	}

	initialize_vma(self)

	create_swapchain(self, app.width, app.height)

	if !slang_init(self) {
		log.errorf("Could not initialize Slang")
		return false
	}

	if !create_shaders_slang(self) {
		log.errorf("Could not create shaders")
		return false
	}

	create_descriptor_set_layout(self)

	if self.pipeline = create_graphics_pipeline(self); self.pipeline == 0 {
		log.errorf("Could not create graphics pipeline")
		return false
	}

	create_sync_resources(self)

	self.vertices = []Vertex {
		{pos = {-0.5, -0.5}, color = {1.0, 0.0, 0.0}},
		{pos = {0.5, -0.5}, color = {0.0, 1.0, 0.0}},
		{pos = {0.5, 0.5}, color = {0.0, 0.0, 1.0}},
		{pos = {-0.5, 0.5}, color = {1.0, 1.0, 1.0}},
	}
	self.indices = []u16{0, 1, 2, 2, 3, 0}

	create_command_buffers(self)
	create_texture_image(self)
	create_geometry_buffer(self)
	create_uniform_buffers(self)
	create_descriptor_pool(self)
	create_descriptor_sets(self)

	return true
}

create_texture_image :: proc(engine: ^Engine) {
}

create_descriptor_pool :: proc(engine: ^Engine) {
	pool_size := vk.DescriptorPoolSize {
		type            = .UNIFORM_BUFFER,
		descriptorCount = MAX_FRAMES_IN_FLIGHT,
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = MAX_FRAMES_IN_FLIGHT,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}

	vk_check(vk.CreateDescriptorPool(engine.device, &pool_info, nil, &engine.descriptor_pool))
}

create_descriptor_sets :: proc(engine: ^Engine) {
	layouts := [MAX_FRAMES_IN_FLIGHT]vk.DescriptorSetLayout{engine.descriptor_set_layout, engine.descriptor_set_layout}

	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = engine.descriptor_pool,
		descriptorSetCount = MAX_FRAMES_IN_FLIGHT,
		pSetLayouts        = &layouts[0],
	}

	vk_check(vk.AllocateDescriptorSets(engine.device, &alloc_info, raw_data(engine.descriptor_sets[:])))

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer_info := vk.DescriptorBufferInfo {
			buffer = engine.uniform_buffers[i],
			offset = 0,
			range  = size_of(UniformBufferObject),
		}

		descriptor_write := vk.WriteDescriptorSet {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = engine.descriptor_sets[i],
			dstBinding      = 0,
			dstArrayElement = 0,
			descriptorCount = 1,
			descriptorType  = .UNIFORM_BUFFER,
			pBufferInfo     = &buffer_info,
		}

		vk.UpdateDescriptorSets(engine.device, 1, &descriptor_write, 0, nil)
	}
}

engine_render :: proc(app: ^App) {
	if app.engine.require_swapchain_recreate {
		vk.DeviceWaitIdle(app.engine.device)
		cleanup_swapchain(&app.engine)
		create_swapchain(&app.engine, app.width, app.height)

		app.engine.require_swapchain_recreate = false
	}

	app.engine.next_signal_value += 1
	signal_value := app.engine.next_signal_value
	frame_res_index := app.engine.frame_index % MAX_FRAMES_IN_FLIGHT
	app.engine.frame_index += 1

	if signal_value > MAX_FRAMES_IN_FLIGHT {
		wait_value := signal_value - MAX_FRAMES_IN_FLIGHT
		wait_info := vk.SemaphoreWaitInfo {
			sType          = .SEMAPHORE_WAIT_INFO,
			semaphoreCount = 1,
			pSemaphores    = &app.engine.timeline_semaphore,
			pValues        = &wait_value,
		}
		vk_check(vk.WaitSemaphores(app.engine.device, &wait_info, max(u64)))
	}

	// now its safe to start recording commands
	res := &app.engine.frame_resources[frame_res_index]
	vk.ResetCommandPool(app.engine.device, res.command_pool, {})

	// get the resources for this frame
	image_acquire_semaphore := app.engine.frame_resources[frame_res_index].image_acquired_semaphore

	image_index: u32
	acquire_result := vk.AcquireNextImageKHR(
		app.engine.device,
		app.engine.swapchain,
		max(u64),
		res.image_acquired_semaphore,
		0,
		&image_index,
	)
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		app.engine.require_swapchain_recreate = true
		return
	} else if acquire_result == .SUBOPTIMAL_KHR {
		app.engine.require_swapchain_recreate = true
	}

	cmd := res.command_buffer

	// begin recording buffer
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &begin_info))

	// transition the color and depth images
	layout_barriers := []vk.ImageMemoryBarrier2 {
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .COLOR_ATTACHMENT_OPTIMAL,
			image = app.engine.swapchain_images[image_index],
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		},
		{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.EARLY_FRAGMENT_TESTS},
			srcAccessMask = {},
			dstStageMask = {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS},
			dstAccessMask = {.DEPTH_STENCIL_ATTACHMENT_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			image = app.engine.depth_image,
			subresourceRange = {aspectMask = {.DEPTH}, levelCount = 1, layerCount = 1},
		},
	}

	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = u32(len(layout_barriers)),
		pImageMemoryBarriers    = raw_data(layout_barriers),
	}
	vk.CmdPipelineBarrier2(cmd, &dep_info)

	// setup the attachments (color and depth) and begin rendering (dynamic)
	color_attach_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = app.engine.swapchain_image_view[image_index],
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR, // clear the image
		storeOp = .STORE, // keep data for presentation
		clearValue = {color = {float32 = {0.1, 0.1, 0.1, 1}}},
	}

	depth_attach_info := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = app.engine.depth_image_view,
		imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR, // clear the depth data
		storeOp = .DONT_CARE, // dont care after rendering
		clearValue = {depthStencil = {depth = 1}},
	}

	rendering_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		renderArea = {
			offset = {0, 0},
			extent = {width = app.engine.swapchain_width, height = app.engine.swapchain_height},
		},
		layerCount = 1,
		colorAttachmentCount = 1,
		pColorAttachments = &color_attach_info,
		pDepthAttachment = &depth_attach_info,
	}

	// begin dynamic rendering
	vk.CmdBeginRendering(cmd, &rendering_info)
	{
		// set the viewport and scissor state
		viewport := vk.Viewport {
			x        = 0,
			y        = 0,
			width    = f32(app.engine.swapchain_width),
			height   = f32(app.engine.swapchain_height),
			minDepth = 0,
			maxDepth = 1,
		}
		vk.CmdSetViewport(cmd, 0, 1, &viewport)

		scissor := vk.Rect2D {
			offset = {x = 0, y = 0},
			extent = {width = app.engine.swapchain_width, height = app.engine.swapchain_height},
		}
		vk.CmdSetScissor(cmd, 0, 1, &scissor)

		// draw our triangle
		vk.CmdBindPipeline(cmd, .GRAPHICS, app.engine.pipeline)

		offset: vk.DeviceSize = 0
		vk.CmdBindVertexBuffers(cmd, 0, 1, &app.engine.geometry_buffer, &offset)
		vk.CmdBindIndexBuffer(cmd, app.engine.geometry_buffer, app.engine.index_buffer_offset, .UINT16)
		vk.CmdBindDescriptorSets(
			cmd,
			.GRAPHICS,
			app.engine.pipeline_layout,
			0,
			1,
			&app.engine.descriptor_sets[frame_res_index],
			0,
			nil,
		)

		vk.CmdDrawIndexed(cmd, u32(len(app.engine.indices)), 1, 0, 0, 0)
	}
	// end dynamic rendering
	vk.CmdEndRendering(cmd)

	// transition the image from color attachment to presentation so we can show it
	present_layout_barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstStageMask = {}, // cache is flushed, layout is transitioned
		dstAccessMask = {},
		oldLayout = .COLOR_ATTACHMENT_OPTIMAL,
		newLayout = .PRESENT_SRC_KHR,
		image = app.engine.swapchain_images[image_index],
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}

	present_dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &present_layout_barrier,
	}

	vk.CmdPipelineBarrier2(cmd, &present_dep_info)

	vk_check(vk.EndCommandBuffer(cmd))

	// ensure swapchain image is actually available to start color output
	image_acquired_wait_info := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = res.image_acquired_semaphore,
		stageMask = {.COLOR_ATTACHMENT_OUTPUT},
	}

	// signal that the image can be presented
	semaphore_signals := []vk.SemaphoreSubmitInfo {
		{ 	// render work completion signal
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = app.engine.render_complete_semaphores[image_index],
			stageMask = {.ALL_GRAPHICS},
		},
		{ 	// entire frame is completed (timeline)
			sType     = .SEMAPHORE_SUBMIT_INFO,
			semaphore = app.engine.timeline_semaphore,
			value     = signal_value,
			stageMask = {.ALL_COMMANDS},
		},
	}

	cmd_submit_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = cmd,
	}

	update_uniform_buffer(&app.engine, frame_res_index)

	submit_info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &image_acquired_wait_info, // ensure the image is ready
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_submit_info,
		signalSemaphoreInfoCount = u32(len(semaphore_signals)),
		pSignalSemaphoreInfos    = raw_data(semaphore_signals),
	}

	vk_check(vk.QueueSubmit2(app.engine.graphics_queue, 1, &submit_info, 0))

	// present the image
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &app.engine.render_complete_semaphores[image_index], // render work completed semaphore
		swapchainCount     = 1,
		pSwapchains        = &app.engine.swapchain,
		pImageIndices      = &image_index,
	}

	present_result := vk.QueuePresentKHR(app.engine.graphics_queue, &present_info)
	if present_result == .ERROR_OUT_OF_DATE_KHR {
		app.engine.require_swapchain_recreate = true
	} else if present_result == .SUBOPTIMAL_KHR {
		app.engine.require_swapchain_recreate = true
	} else if present_result != .SUCCESS {
		log.errorf("QueuePresentKHR failed")
	}
}

create_sync_resources :: proc(self: ^Engine) {
	semaphore_type_info := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
		initialValue  = 0,
	}

	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &semaphore_type_info,
	}

	vk_check(vk.CreateSemaphore(self.device, &semaphore_info, nil, &self.timeline_semaphore))

	// per frame image-acquire semaphores
	for &res in self.frame_resources {
		// create the binary semaphores
		binary_semaphore_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		vk_check(vk.CreateSemaphore(self.device, &binary_semaphore_info, nil, &res.image_acquired_semaphore))
	}
}

create_command_buffers :: proc(self: ^Engine) {
	for &res in self.frame_resources {
		pool_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			queueFamilyIndex = self.gfx_queue_fam_idx,
		}

		vk_check(vk.CreateCommandPool(self.device, &pool_info, nil, &res.command_pool))

		// create the command buffer for this frame
		cmd_alloc_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = res.command_pool,
			level              = .PRIMARY,
			commandBufferCount = 1,
		}

		vk_check(vk.AllocateCommandBuffers(self.device, &cmd_alloc_info, &res.command_buffer))
	}
}

initialize_vma :: proc(self: ^Engine) {
	vulkan_functions := vma.create_vulkan_functions()

	create_info := vma.Allocator_Create_Info {
		flags              = {.Buffer_Device_Address},
		instance           = self.instance,
		physical_device    = self.physical_device,
		device             = self.device,
		vulkan_api_version = vk.API_VERSION_1_4,
		vulkan_functions   = &vulkan_functions,
	}

	vk_check(vma.create_allocator(create_info, &self.vma_allocator))
}

create_vulkan_instance :: proc(self: ^Engine) {
	vk.load_proc_addresses_global(rawptr(sdl.Vulkan_GetVkGetInstanceProcAddr()))
	assert(vk.CreateInstance != nil, "vulkan function pointers not loaded")

	app_info := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "First Triangle",
		apiVersion       = vk.API_VERSION_1_4,
	}

	extension_count: u32 = 0
	sdl_extensions := sdl.Vulkan_GetInstanceExtensions(&extension_count)
	extensions := make([dynamic]cstring, context.temp_allocator)
	append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	for i in 0 ..< int(extension_count) {
		append(&extensions, sdl_extensions[i])
	}

	requested_layers := []cstring{"VK_LAYER_KHRONOS_validation"}

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

	vk_check(vk.CreateInstance(&create_info, nil, &self.instance))

	vk.load_proc_addresses_instance(self.instance)
}

create_vulkan_surface :: proc(app: ^App) -> bool {
	if !sdl.Vulkan_CreateSurface(app.window, app.engine.instance, nil, &app.engine.surface) {
		log.errorf("Failed to create vulkan surface: %s", sdl.GetError())
		return false
	}

	return true
}

find_physical_device :: proc(self: ^Engine) -> vk.PhysicalDevice {
	device_count: u32 = 0
	vk.EnumeratePhysicalDevices(self.instance, &device_count, nil)
	if device_count == 0 {
		log.errorf("No Vulkan physical devices found")
		return nil
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

	// make sure that desired swapchain format is supported
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
		return nil
	}

	return physical_device
}

find_graphics_queue :: proc(self: ^Engine) -> bool {
	queue_fam_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties2(self.physical_device, &queue_fam_count, nil)
	queue_fam_props := make([]vk.QueueFamilyProperties2, queue_fam_count, context.temp_allocator)
	for &p in queue_fam_props {p.sType = .QUEUE_FAMILY_PROPERTIES_2}
	vk.GetPhysicalDeviceQueueFamilyProperties2(self.physical_device, &queue_fam_count, raw_data(queue_fam_props))

	for i: u32 = 0; i < queue_fam_count; i += 1 {
		has_present_support: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(self.physical_device, i, self.surface, &has_present_support)

		props := queue_fam_props[i]
		if .GRAPHICS in props.queueFamilyProperties.queueFlags && has_present_support {
			self.gfx_queue_fam_idx = i
			return true
		}
	}

	return false
}

create_logical_device :: proc(self: ^Engine) -> bool {
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
	supported_features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &features_12,
	}
	vk.GetPhysicalDeviceFeatures2(self.physical_device, &supported_features)

	if !features_13.dynamicRendering || !features_13.synchronization2 || !features_12.timelineSemaphore {
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
		sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext               = &enabled_features_13,
		timelineSemaphore   = true,
		bufferDeviceAddress = true,
	}
	enabled_features_11 := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext                = &enabled_features_12,
		shaderDrawParameters = true,
	}
	enabled_features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &enabled_features_11,
	}

	queue_priorities := []f32{1.0}
	gfx_queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = self.gfx_queue_fam_idx,
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
		pEnabledFeatures        = nil, // features struct chain is set in pNext
	}

	vk_check(vk.CreateDevice(self.physical_device, &dev_create_info, nil, &self.device))

	vk.load_proc_addresses_device(self.device)
	vk.GetDeviceQueue(self.device, self.gfx_queue_fam_idx, 0, &self.graphics_queue)
	if self.graphics_queue == nil {
		log.errorf("Could not get graphics queue")
		return false
	}

	return true
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

create_descriptor_set_layout :: proc(self: ^Engine) {
	ubo_layout_binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .UNIFORM_BUFFER,
		descriptorCount = 1,
		stageFlags      = {.VERTEX},
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &ubo_layout_binding,
	}

	vk_check(vk.CreateDescriptorSetLayout(self.device, &layout_info, nil, &self.descriptor_set_layout))
}

create_graphics_pipeline :: proc(self: ^Engine) -> vk.Pipeline {
	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &self.descriptor_set_layout,
		pushConstantRangeCount = 0,
	}

	log.debug("Creating pipeline layout...")
	vk_check(vk.CreatePipelineLayout(self.device, &pipeline_layout_info, nil, &self.pipeline_layout))
	log.debug("Pipeline layout created")

	shader_stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = self.shader_module,
			pName = "vertMain",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = self.shader_module,
			pName = "fragMain",
		},
	}

	binding_description := vertex_binding_description()
	attribute_descriptions := vertex_attribute_descriptions()
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		pVertexBindingDescriptions      = &binding_description,
		vertexBindingDescriptionCount   = 1,
		pVertexAttributeDescriptions    = &attribute_descriptions[0],
		vertexAttributeDescriptionCount = len(&attribute_descriptions),
	}

	input_assembly_info := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	depth_stencil_info := vk.PipelineDepthStencilStateCreateInfo {
		sType             = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
		depthTestEnable   = true,
		depthWriteEnable  = true,
		depthCompareOp    = .LESS,
		stencilTestEnable = false,
	}

	viewport_info := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = nil,
		scissorCount  = 1,
		pScissors     = nil,
	}

	raster_info := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		cullMode                = {.BACK},
		frontFace               = .COUNTER_CLOCKWISE,
		depthBiasEnable         = false,
		lineWidth               = 1.0,
	}

	multisample_info := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	attach_state := vk.PipelineColorBlendAttachmentState {
		blendEnable    = false,
		colorWriteMask = {.R, .G, .B, .A},
	}

	blend_info := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &attach_state,
	}

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	color_format := vk.Format(SWAPCHAIN_FORMAT)
	render_info := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &color_format,
		depthAttachmentFormat   = DEPTH_FORMAT,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &render_info,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages[:]),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly_info,
		pViewportState      = &viewport_info,
		pRasterizationState = &raster_info,
		pMultisampleState   = &multisample_info,
		pDepthStencilState  = &depth_stencil_info,
		pColorBlendState    = &blend_info,
		pDynamicState       = &dynamic_state_info,
		layout              = self.pipeline_layout,
	}

	log.debug("Creating graphics pipeline...")
	pipeline: vk.Pipeline
	vk_check(vk.CreateGraphicsPipelines(self.device, 0, 1, &pipeline_info, nil, &pipeline))

	return pipeline
}


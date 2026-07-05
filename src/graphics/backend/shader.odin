package backend

import vk "vendor:vulkan"

shader_module_create :: proc(ctx: ^VulkanContext, spirv: []u32) -> vk.ShaderModule {
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spirv) * size_of(u32),
		pCode    = raw_data(spirv),
	}
	module: vk.ShaderModule
	vk_check(vk.CreateShaderModule(ctx.device, &info, nil, &module))
	return module
}

shader_module_destroy :: proc(ctx: ^VulkanContext, module: vk.ShaderModule) {
	vk.DestroyShaderModule(ctx.device, module, nil)
}


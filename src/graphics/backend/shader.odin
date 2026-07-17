package backend

import vk "vendor:vulkan"

ShaderModule :: distinct vk.ShaderModule

ShaderStage :: enum u8 {
	Vertex,
	Fragment,
	Compute,
}

ShaderStageDesc :: struct {
	module: ShaderModule,
	entry:  cstring,
	stage:  ShaderStage,
}

shader_stage_to_vk :: proc(stage: ShaderStage) -> vk.ShaderStageFlags {
	switch stage {
	case .Vertex:
		return {.VERTEX}
	case .Fragment:
		return {.FRAGMENT}
	case .Compute:
		return {.COMPUTE}
	}
	return {}
}

shader_stage_info :: proc(desc: ShaderStageDesc) -> vk.PipelineShaderStageCreateInfo {
	return {
		sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = shader_stage_to_vk(desc.stage),
		module = vk.ShaderModule(desc.module),
		pName = desc.entry,
	}
}

shader_module_create :: proc(ctx: ^VulkanContext, spirv: []u32) -> ShaderModule {
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spirv) * size_of(u32),
		pCode    = raw_data(spirv),
	}
	module: vk.ShaderModule
	vk_check(vk.CreateShaderModule(ctx.device, &info, nil, &module))
	return ShaderModule(module)
}

shader_module_destroy :: proc(ctx: ^VulkanContext, module: ShaderModule) {
	vk.DestroyShaderModule(ctx.device, vk.ShaderModule(module), nil)
}

package graphics

import "core:log"

import "backend"

import vk "vendor:vulkan"

PipelineKind :: enum u8 {
	Shadow,
	Shadow_Directional,
	Mesh,
	Skybox,
	UI,
	Particle_Draw,
	Particle_Compute,
	Debug_Shadow,
}

PipelineRegistry :: struct {
	pipelines:    [PipelineKind]backend.Pipeline,
	configs:      [PipelineKind]backend.PipelineConfig, // nil (no case matched) for unregistered kinds
	shaders:      [PipelineKind]ShaderHandle,
	module_names: [PipelineKind]string,
}

pipeline_register :: proc(
	self: ^Engine,
	kind: PipelineKind,
	shader: ShaderHandle,
	config: ^backend.GraphicsPipelineConfig,
	shader_stages: []vk.PipelineShaderStageCreateInfo,
) {
	self.pipeline_registry.pipelines[kind] = backend.pipeline_create(self.vk_ctx.device, config, shader_stages)
	self.pipeline_registry.configs[kind] = config
	self.pipeline_registry.shaders[kind] = shader
}

pipeline_register_compute :: proc(
	self: ^Engine,
	kind: PipelineKind,
	shader: ShaderHandle,
	config: ^backend.ComputePipelineConfig,
	shader_stage: vk.PipelineShaderStageCreateInfo,
) {
	self.pipeline_registry.pipelines[kind] = backend.pipeline_create_compute(self.vk_ctx.device, config, shader_stage)
	self.pipeline_registry.configs[kind] = config
	self.pipeline_registry.shaders[kind] = shader
}

get_pipeline :: #force_inline proc(reg: ^PipelineRegistry, kind: PipelineKind) -> backend.Pipeline {
	return reg.pipelines[kind]
}

pipeline_rebuild :: proc(self: ^Engine, kind: PipelineKind, new_shader_stages: []vk.PipelineShaderStageCreateInfo) {
	config := self.pipeline_registry.configs[kind]
	if config == nil {
		log.errorf("pipeline_rebuild '%v': no config registered", kind)
		return
	}

	old_pipeline := self.pipeline_registry.pipelines[kind]

	vk.DeviceWaitIdle(self.vk_ctx.device)
	vk.DestroyPipeline(self.vk_ctx.device, old_pipeline.pipeline, nil)
	vk.DestroyPipelineLayout(self.vk_ctx.device, old_pipeline.layout, nil)

	switch cfg in config {
	case ^GraphicsPipelineConfig:
		self.pipeline_registry.pipelines[kind] = backend.pipeline_create(self.vk_ctx.device, cfg, new_shader_stages)
	case ^ComputePipelineConfig:
		self.pipeline_registry.pipelines[kind] = backend.pipeline_create_compute(
			self.vk_ctx.device,
			cfg,
			new_shader_stages[0],
		)
	case nil:
	}
	log.infof("Rebuilt pipeline: %v", kind)
}

destroy_pipeline_registry :: proc(device: vk.Device, reg: ^PipelineRegistry) {
	for pipeline in reg.pipelines {
		vk.DestroyPipeline(device, pipeline.pipeline, nil)
		vk.DestroyPipelineLayout(device, pipeline.layout, nil)
	}
	for config in reg.configs {
		switch cfg in config {
		case ^backend.GraphicsPipelineConfig:
			free(cfg)
		case ^backend.ComputePipelineConfig:
			free(cfg)
		case nil:
		}
	}
}

pipeline_reload :: proc(self: ^Engine, kind: PipelineKind, module_name: string) {
	config := self.pipeline_registry.configs[kind]

	// load_shader reuses the same handle on a repeat load and destroys the old vk.ShaderModule
	// itself, so there's nothing to manually destroy here.
	switch _ in config {
	case ^GraphicsPipelineConfig:
		new_handle, compile_ok := shader_load(self, module_name, {VERTEX_ENTRY, FRAGMENT_MAIN})
		if !compile_ok {
			log.errorf("pipeline_reload '%v': shader compilation failed, keeping old pipeline", kind)
			return
		}
		shader_module := shader_get(self, new_handle)
		new_stages := []vk.PipelineShaderStageCreateInfo {
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.VERTEX},
				module = shader_module,
				pName = DEFAULT_VERTEX_ENTRY,
			},
			{
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.FRAGMENT},
				module = shader_module,
				pName = DEFAULT_FRAGMENT_ENTRY,
			},
		}
		pipeline_rebuild(self, kind, new_stages)

	case ^ComputePipelineConfig:
		new_handle, compile_ok := shader_load(self, module_name, {COMPUTE_MAIN})
		if !compile_ok {
			log.errorf("pipeline_reload '%v': shader compilation failed, keeping old pipeline", kind)
			return
		}
		shader_module := shader_get(self, new_handle)
		new_stage := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.COMPUTE},
			module = shader_module,
			pName  = cstring(COMPUTE_MAIN),
		}
		pipeline_rebuild(self, kind, []vk.PipelineShaderStageCreateInfo{new_stage})

	case nil:
		log.errorf("pipeline_reload '%v': no config registered", kind)
	}
}


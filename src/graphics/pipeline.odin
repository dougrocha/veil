package graphics

import "core:log"

import "backend"

PipelineKind :: enum u8 {
	Shadow,
	Mesh,
	Skybox,
	UI,
	Particle_Draw,
	Particle_Compute,
	Debug_View,
	Debug_Line,
	Debug_Line_Overlay,
	Debug_Sector,
}

PipelineRegistry :: struct {
	pipelines:    [PipelineKind]backend.Pipeline,
	configs:      [PipelineKind]backend.PipelineConfig, // nil (no case matched) for unregistered kinds
	shaders:      [PipelineKind]ShaderHandle,
	module_names: [PipelineKind]string,
}

// Every pipeline uses one shader module with the default entry point per stage;
// register/rebuild derive the stage descs from the handle instead of taking them.
default_graphics_stages :: proc(self: ^Engine, shader: ShaderHandle) -> [2]backend.ShaderStageDesc {
	module := shader_get(self, shader)
	return {
		{module = module, entry = DEFAULT_VERTEX_ENTRY, stage = .Vertex},
		{module = module, entry = DEFAULT_FRAGMENT_ENTRY, stage = .Fragment},
	}
}

default_compute_stage :: proc(self: ^Engine, shader: ShaderHandle) -> backend.ShaderStageDesc {
	return {module = shader_get(self, shader), entry = DEFAULT_COMPUTE_ENTRY, stage = .Compute}
}

pipeline_register :: proc(
	self: ^Engine,
	kind: PipelineKind,
	shader: ShaderHandle,
	config: backend.GraphicsPipelineConfig,
) {
	config := config
	stages := default_graphics_stages(self, shader)
	self.pipeline_registry.pipelines[kind] = backend.pipeline_create(self.vk_ctx.device, &config, stages[:])
	self.pipeline_registry.configs[kind] = config
	self.pipeline_registry.shaders[kind] = shader
}

pipeline_register_compute :: proc(
	self: ^Engine,
	kind: PipelineKind,
	shader: ShaderHandle,
	config: backend.ComputePipelineConfig,
) {
	config := config
	stage := default_compute_stage(self, shader)
	self.pipeline_registry.pipelines[kind] = backend.pipeline_create_compute(self.vk_ctx.device, &config, stage)
	self.pipeline_registry.configs[kind] = config
	self.pipeline_registry.shaders[kind] = shader
}

get_pipeline :: #force_inline proc(reg: ^PipelineRegistry, kind: PipelineKind) -> backend.Pipeline {
	return reg.pipelines[kind]
}

pipeline_rebuild :: proc(self: ^Engine, kind: PipelineKind) {
	config := self.pipeline_registry.configs[kind]
	if config == nil {
		log.errorf("pipeline_rebuild '%v': no config registered", kind)
		return
	}

	shader := self.pipeline_registry.shaders[kind]
	old_pipeline := self.pipeline_registry.pipelines[kind]

	backend.device_wait_idle(&self.vk_ctx)
	backend.pipeline_destroy(&self.vk_ctx, old_pipeline)

	switch &cfg in config {
	case backend.GraphicsPipelineConfig:
		stages := default_graphics_stages(self, shader)
		self.pipeline_registry.pipelines[kind] = backend.pipeline_create(self.vk_ctx.device, &cfg, stages[:])
	case backend.ComputePipelineConfig:
		self.pipeline_registry.pipelines[kind] = backend.pipeline_create_compute(
			self.vk_ctx.device,
			&cfg,
			default_compute_stage(self, shader),
		)
	case nil:
	}
	log.infof("Rebuilt pipeline: %v", kind)
}

destroy_pipeline_registry :: proc(ctx: ^backend.VulkanContext, reg: ^PipelineRegistry) {
	for pipeline in reg.pipelines {
		backend.pipeline_destroy(ctx, pipeline)
	}
}

make_shadow_config :: proc(engine: ^Engine) -> backend.GraphicsPipelineConfig {
	config := backend.pipeline_default_config()
	backend.pipeline_config_set_descriptor_layouts(&config, {engine.texture_system.descriptor.layout})
	config.rasterization.cullMode = {}
	config.rasterization.depthBiasEnable = true
	config.depth_stencil.depthCompareOp = .LESS_OR_EQUAL
	config.rendering_info = {
		sType                 = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount  = 0,
		depthAttachmentFormat = backend.DEPTH_FORMAT,
	}
	config.push_constant_range = {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = size_of(ShadowPushConstants),
	}
	return config
}

register_shadow_pipelines :: proc(engine: ^Engine, shadow_handle: ShaderHandle) {
	pipeline_register(engine, .Shadow, shadow_handle, make_shadow_config(engine))
}

register_ui_pipeline :: proc(engine: ^Engine, ui_handle: ShaderHandle) {
	config := backend.pipeline_default_config()
	config.rasterization.cullMode = {}
	backend.pipeline_config_disable_depth(&config)
	backend.pipeline_config_set_blend(&config, .Alpha)
	backend.pipeline_config_set_descriptor_layouts(
		&config,
		{engine.texture_system.descriptor.layout, engine.global_descriptor.layout},
	)
	config.push_constant_range = {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = size_of(UIPushConstants),
	}
	pipeline_register(engine, .UI, ui_handle, config)
}

register_mesh_pipeline :: proc(engine: ^Engine, mesh_handle: ShaderHandle) {
	config := backend.pipeline_default_config()
	config.multi_sample.rasterizationSamples = engine.vk_ctx.msaa_samples
	config.dynamic_states[3] = .DEPTH_WRITE_ENABLE
	config.dynamic_state_count = 4
	backend.pipeline_config_set_blend(&config, .Alpha)
	backend.pipeline_config_set_descriptor_layouts(
		&config,
		{engine.texture_system.descriptor.layout, engine.global_descriptor.layout},
	)
	config.push_constant_range = {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = size_of(PushConstants),
	}
	pipeline_register(engine, .Mesh, mesh_handle, config)
}

register_particle_pipelines :: proc(engine: ^Engine, particle_handle: ShaderHandle) {
	draw_config := backend.pipeline_default_config()
	draw_config.input_assembly.topology = .POINT_LIST
	draw_config.rasterization.cullMode = {}
	draw_config.multi_sample.rasterizationSamples = engine.vk_ctx.msaa_samples
	backend.pipeline_config_disable_depth(&draw_config)
	backend.pipeline_config_set_blend(&draw_config, .Alpha)
	draw_config.push_constant_range = {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = size_of(ParticlePushConstants),
	}
	pipeline_register(engine, .Particle_Draw, particle_handle, draw_config)

	compute_config: backend.ComputePipelineConfig
	compute_config.push_constant_range = {
		stageFlags = {.COMPUTE},
		size       = size_of(ParticlePushConstants),
	}
	pipeline_register_compute(engine, .Particle_Compute, particle_handle, compute_config)
}

register_skybox_pipeline :: proc(engine: ^Engine, skybox_handle: ShaderHandle) {
	config := backend.pipeline_default_config()
	config.rasterization.cullMode = {}
	config.depth_stencil.depthWriteEnable = false
	config.depth_stencil.depthCompareOp = .LESS_OR_EQUAL
	config.multi_sample.rasterizationSamples = engine.vk_ctx.msaa_samples
	backend.pipeline_config_set_descriptor_layouts(&config, {engine.global_descriptor.layout})
	config.push_constant_range = {
		stageFlags = {.VERTEX, .FRAGMENT},
		size       = size_of(SkyboxPushConstants),
	}
	pipeline_register(engine, .Skybox, skybox_handle, config)
}

register_debug_view_pipeline :: proc(engine: ^Engine, debug_view_handle: ShaderHandle) {
	config := backend.pipeline_default_config()
	config.rasterization.cullMode = {}
	backend.pipeline_config_disable_depth(&config)
	config.rendering_info.depthAttachmentFormat = .UNDEFINED
	backend.pipeline_config_set_descriptor_layouts(
		&config,
		{engine.texture_system.descriptor.layout, engine.global_descriptor.layout},
	)
	config.push_constant_range = {
		stageFlags = {.FRAGMENT},
		size       = size_of(DebugViewPushConstants),
	}
	pipeline_register(engine, .Debug_View, debug_view_handle, config)
}

pipeline_reload :: proc(self: ^Engine, kind: PipelineKind, module_name: string) {
	config := self.pipeline_registry.configs[kind]

	// load_shader reuses the same handle on a repeat load and destroys the old vk.ShaderModule
	// itself, so there's nothing to manually destroy here.
	entry_points: []string
	switch _ in config {
	case backend.GraphicsPipelineConfig:
		entry_points = {VERTEX_ENTRY, FRAGMENT_MAIN}
	case backend.ComputePipelineConfig:
		entry_points = {COMPUTE_MAIN}
	case nil:
		log.errorf("pipeline_reload '%v': no config registered", kind)
		return
	}

	_, compile_ok := shader_load(self, module_name, entry_points)
	if !compile_ok {
		log.errorf("pipeline_reload '%v': shader compilation failed, keeping old pipeline", kind)
		return
	}
	pipeline_rebuild(self, kind)
}

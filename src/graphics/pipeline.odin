package graphics

import "core:log"

import "backend"

PipelineKind :: enum u8 {
	Shadow, // spot + point lights
	Shadow_Directional, // directional cascades, depth-clamped
	Mesh,
	Skybox,
	UI,
	Particle_Draw,
	Particle_Compute,
	Tonemap_Compute,
	Bloom_Down_Compute,
	Bloom_Up_Compute,
	Debug_View,
	Debug_Line,
	Debug_Line_Overlay,
	Debug_Sector,
}

PipelineRegistry :: struct {
	pipelines: [PipelineKind]backend.Pipeline,
	configs:   [PipelineKind]backend.PipelineConfig, // nil (no case matched) for unregistered kinds
	shaders:   [PipelineKind]backend.Shader,
}

// Every pipeline uses one shader with the default entry point per stage;
// register/rebuild derive the stage descs from the shader instead of taking them.
default_graphics_stages :: proc(shader: backend.Shader) -> [2]backend.ShaderStageDesc {
	return {{shader = shader, entry = VERTEX_ENTRY}, {shader = shader, entry = FRAGMENT_MAIN}}
}

default_compute_stage :: proc(shader: backend.Shader) -> backend.ShaderStageDesc {
	return {shader = shader, entry = COMPUTE_MAIN}
}

pipeline_register :: proc(
	self: ^Engine,
	kind: PipelineKind,
	shader: backend.Shader,
	config: backend.GraphicsPipelineConfig,
) {
	config := config
	stages := default_graphics_stages(shader)
	self.pipeline_registry.pipelines[kind] = backend.pipeline_create(&self.vk_ctx, &config, stages[:])
	self.pipeline_registry.configs[kind] = config
	self.pipeline_registry.shaders[kind] = shader
}

pipeline_register_compute :: proc(
	self: ^Engine,
	kind: PipelineKind,
	shader: backend.Shader,
	config: backend.ComputePipelineConfig,
) {
	config := config
	stage := default_compute_stage(shader)
	self.pipeline_registry.pipelines[kind] = backend.pipeline_create_compute(&self.vk_ctx, &config, stage)
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
		stages := default_graphics_stages(shader)
		self.pipeline_registry.pipelines[kind] = backend.pipeline_create(&self.vk_ctx, &cfg, stages[:])
	case backend.ComputePipelineConfig:
		self.pipeline_registry.pipelines[kind] = backend.pipeline_create_compute(
			&self.vk_ctx,
			&cfg,
			default_compute_stage(shader),
		)
	case nil:
	}
	log.infof("Rebuilt pipeline: %v", kind)
}

destroy_pipeline_registry :: proc(ctx: ^backend.Context, reg: ^PipelineRegistry) {
	for pipeline in reg.pipelines {
		backend.pipeline_destroy(ctx, pipeline)
	}
}

make_shadow_config :: proc(engine: ^Engine) -> backend.GraphicsPipelineConfig {
	config := backend.pipeline_default_config()
	backend.pipeline_config_set_no_cull(&config)
	backend.pipeline_config_enable_depth_bias(&config)
	backend.pipeline_config_set_depth_compare(&config, .LessOrEqual)
	backend.pipeline_config_set_layout(&config, shadow_pass_layout())
	backend.pipeline_config_set_push_constant(&config, size_of(ShadowPushConstants), {.Vertex, .Fragment})
	return config
}

register_shadow_pipelines :: proc(engine: ^Engine, shadow_handle: backend.Shader) {
	pipeline_register(engine, .Shadow, shadow_handle, make_shadow_config(engine))

	// Cascades only cover a slice of the scene along the light direction, so casters between the
	// light and a cascade's near plane would be clipped; depth clamp flattens them onto it instead.
	directional_config := make_shadow_config(engine)
	backend.pipeline_config_enable_depth_clamp(&directional_config)
	pipeline_register(engine, .Shadow_Directional, shadow_handle, directional_config)
}

register_ui_pipeline :: proc(engine: ^Engine, ui_handle: backend.Shader) {
	config := backend.pipeline_default_config()
	backend.pipeline_config_set_no_cull(&config)
	backend.pipeline_config_disable_depth(&config)
	backend.pipeline_config_set_layout(&config, overlay_pass_layout(&engine.vk_ctx, &engine.render_targets))
	backend.pipeline_config_set_blend(&config, .Alpha)
	backend.pipeline_config_set_push_constant(&config, size_of(UIPushConstants), {.Vertex, .Fragment})
	pipeline_register(engine, .UI, ui_handle, config)
}

register_mesh_pipeline :: proc(engine: ^Engine, mesh_handle: backend.Shader) {
	config := backend.pipeline_default_config()
	backend.pipeline_config_set_layout(&config, main_pass_layout(&engine.vk_ctx, &engine.render_targets))
	backend.pipeline_config_set_depth_dynamic(&config)
	backend.pipeline_config_set_blend(&config, .Alpha)
	backend.pipeline_config_set_push_constant(&config, size_of(PushConstants), {.Vertex, .Fragment})
	pipeline_register(engine, .Mesh, mesh_handle, config)
}

register_particle_pipelines :: proc(engine: ^Engine, particle_handle: backend.Shader) {
	draw_config := backend.pipeline_default_config()
	backend.pipeline_config_set_topology_points(&draw_config)
	backend.pipeline_config_set_no_cull(&draw_config)
	backend.pipeline_config_set_layout(&draw_config, main_pass_layout(&engine.vk_ctx, &engine.render_targets))
	backend.pipeline_config_disable_depth(&draw_config)
	backend.pipeline_config_set_blend(&draw_config, .Alpha)
	backend.pipeline_config_set_push_constant(&draw_config, size_of(ParticlePushConstants), {.Vertex, .Fragment})
	pipeline_register(engine, .Particle_Draw, particle_handle, draw_config)

	compute_config: backend.ComputePipelineConfig
	backend.pipeline_config_set_push_constant_compute(&compute_config, size_of(ParticlePushConstants), {.Compute})
	pipeline_register_compute(engine, .Particle_Compute, particle_handle, compute_config)
}

// Compute post passes: set 0 = bindless textures, set 1 = bindless storage images.
make_post_compute_config :: proc(engine: ^Engine, push_constant_size: int) -> backend.ComputePipelineConfig {
	config: backend.ComputePipelineConfig
	backend.pipeline_config_set_push_constant_compute(&config, push_constant_size, {.Compute})
	return config
}

register_tonemap_pipeline :: proc(engine: ^Engine, tonemap_handle: backend.Shader) {
	config := make_post_compute_config(engine, size_of(TonemapPushConstants))
	pipeline_register_compute(engine, .Tonemap_Compute, tonemap_handle, config)
}

register_bloom_pipelines :: proc(engine: ^Engine, down_handle, up_handle: backend.Shader) {
	config := make_post_compute_config(engine, size_of(BloomPushConstants))
	pipeline_register_compute(engine, .Bloom_Down_Compute, down_handle, config)
	pipeline_register_compute(engine, .Bloom_Up_Compute, up_handle, config)
}

register_skybox_pipeline :: proc(engine: ^Engine, skybox_handle: backend.Shader) {
	config := backend.pipeline_default_config()
	backend.pipeline_config_set_no_cull(&config)
	backend.pipeline_config_set_depth_write_default(&config, false)
	backend.pipeline_config_set_depth_compare(&config, .LessOrEqual)
	backend.pipeline_config_set_layout(&config, main_pass_layout(&engine.vk_ctx, &engine.render_targets))
	backend.pipeline_config_set_push_constant(&config, size_of(SkyboxPushConstants), {.Vertex, .Fragment})
	pipeline_register(engine, .Skybox, skybox_handle, config)
}

register_debug_view_pipeline :: proc(engine: ^Engine, debug_view_handle: backend.Shader) {
	config := backend.pipeline_default_config()
	backend.pipeline_config_set_no_cull(&config)
	backend.pipeline_config_disable_depth(&config)
	backend.pipeline_config_set_layout(&config, overlay_pass_layout(&engine.vk_ctx, &engine.render_targets))
	backend.pipeline_config_set_push_constant(&config, size_of(DebugViewPushConstants), {.Fragment})
	pipeline_register(engine, .Debug_View, debug_view_handle, config)
}

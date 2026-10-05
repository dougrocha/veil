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

// Compute pipelines have nothing to configure; the marker only tells rebuild which create to call.
ComputePipelineDesc :: struct {}

PipelineDesc :: union {
	backend.GraphicsPipelineDesc,
	ComputePipelineDesc,
}

PipelineRegistry :: struct {
	pipelines: [PipelineKind]backend.Pipeline,
	descs:     [PipelineKind]PipelineDesc, // nil for unregistered kinds
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
	desc: backend.GraphicsPipelineDesc,
) {
	stages := default_graphics_stages(shader)
	self.pipeline_registry.pipelines[kind] = backend.pipeline_create(&self.vk_ctx, desc, stages[:])
	self.pipeline_registry.descs[kind] = desc
	self.pipeline_registry.shaders[kind] = shader
}

pipeline_register_compute :: proc(self: ^Engine, kind: PipelineKind, shader: backend.Shader) {
	self.pipeline_registry.pipelines[kind] = backend.pipeline_create_compute(
		&self.vk_ctx,
		default_compute_stage(shader),
	)
	self.pipeline_registry.descs[kind] = ComputePipelineDesc{}
	self.pipeline_registry.shaders[kind] = shader
}

get_pipeline :: #force_inline proc(reg: ^PipelineRegistry, kind: PipelineKind) -> backend.Pipeline {
	return reg.pipelines[kind]
}

pipeline_rebuild :: proc(self: ^Engine, kind: PipelineKind) {
	desc := self.pipeline_registry.descs[kind]
	if desc == nil {
		log.errorf("pipeline_rebuild '%v': no desc registered", kind)
		return
	}

	shader := self.pipeline_registry.shaders[kind]
	old_pipeline := self.pipeline_registry.pipelines[kind]

	backend.device_wait_idle(&self.vk_ctx)
	backend.pipeline_destroy(&self.vk_ctx, old_pipeline)

	switch d in desc {
	case backend.GraphicsPipelineDesc:
		stages := default_graphics_stages(shader)
		self.pipeline_registry.pipelines[kind] = backend.pipeline_create(&self.vk_ctx, d, stages[:])
	case ComputePipelineDesc:
		self.pipeline_registry.pipelines[kind] = backend.pipeline_create_compute(
			&self.vk_ctx,
			default_compute_stage(shader),
		)
	}
	log.infof("Rebuilt pipeline: %v", kind)
}

pipeline_registry_destroy :: proc(ctx: ^backend.Context, reg: ^PipelineRegistry) {
	for pipeline in reg.pipelines {
		backend.pipeline_destroy(ctx, pipeline)
	}
}

shadow_desc :: proc() -> backend.GraphicsPipelineDesc {
	return {
		attachments = shadow_pass_layout(),
		cull = .None,
		depth = {test = true, write = true, bias = true, compare = .LessOrEqual},
	}
}

register_shadow_pipelines :: proc(engine: ^Engine, shadow_handle: backend.Shader) {
	pipeline_register(engine, .Shadow, shadow_handle, shadow_desc())

	// Cascades only cover a slice of the scene along the light direction, so casters between the
	// light and a cascade's near plane would be clipped; depth clamp flattens them onto it instead.
	directional := shadow_desc()
	directional.depth.clamp = true
	pipeline_register(engine, .Shadow_Directional, shadow_handle, directional)
}

register_ui_pipeline :: proc(engine: ^Engine, ui_handle: backend.Shader) {
	desc := backend.GraphicsPipelineDesc {
		attachments = overlay_pass_layout(&engine.vk_ctx, &engine.render_targets),
		cull        = .None,
		blend       = .Alpha,
	}
	pipeline_register(engine, .UI, ui_handle, desc)
}

register_mesh_pipeline :: proc(engine: ^Engine, mesh_handle: backend.Shader) {
	desc := backend.GraphicsPipelineDesc {
		attachments = main_pass_layout(&engine.vk_ctx, &engine.render_targets),
		blend = .Alpha,
		depth = {test = true, write = true, compare = .Less},
	}
	pipeline_register(engine, .Mesh, mesh_handle, desc)
}

register_particle_pipelines :: proc(engine: ^Engine, particle_handle: backend.Shader) {
	draw := backend.GraphicsPipelineDesc {
		attachments = main_pass_layout(&engine.vk_ctx, &engine.render_targets),
		topology    = .Points,
		cull        = .None,
		blend       = .Alpha,
	}
	pipeline_register(engine, .Particle_Draw, particle_handle, draw)
	pipeline_register_compute(engine, .Particle_Compute, particle_handle)
}

register_tonemap_pipeline :: proc(engine: ^Engine, tonemap_handle: backend.Shader) {
	pipeline_register_compute(engine, .Tonemap_Compute, tonemap_handle)
}

register_bloom_pipelines :: proc(engine: ^Engine, down_handle, up_handle: backend.Shader) {
	pipeline_register_compute(engine, .Bloom_Down_Compute, down_handle)
	pipeline_register_compute(engine, .Bloom_Up_Compute, up_handle)
}

register_skybox_pipeline :: proc(engine: ^Engine, skybox_handle: backend.Shader) {
	desc := backend.GraphicsPipelineDesc {
		attachments = main_pass_layout(&engine.vk_ctx, &engine.render_targets),
		cull = .None,
		depth = {test = true, compare = .LessOrEqual},
	}
	pipeline_register(engine, .Skybox, skybox_handle, desc)
}

register_debug_view_pipeline :: proc(engine: ^Engine, debug_view_handle: backend.Shader) {
	desc := backend.GraphicsPipelineDesc {
		attachments = overlay_pass_layout(&engine.vk_ctx, &engine.render_targets),
		cull        = .None,
	}
	pipeline_register(engine, .Debug_View, debug_view_handle, desc)
}

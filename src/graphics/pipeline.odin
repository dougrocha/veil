package graphics

import "core:log"

import "backend"

PipelineRegistry :: struct {
	pipelines: [PipelineKind]backend.Pipeline,
	shaders:   [PipelineKind]backend.Shader, // module each pipeline was built from
}

// Loads every shader module the table names (once each, with the entry points its stages need)
// and creates every pipeline. Depends only on the device: layouts come from format constants.
pipelines_create :: proc(engine: ^Engine) -> (ok: bool) {
	reg := &engine.pipeline_registry

	uses := make(map[string]bit_set[PipelineStage], context.temp_allocator)
	for spec in PIPELINE_SPECS {
		stages := uses[spec.shader]
		stages += {spec.stage}
		uses[spec.shader] = stages
	}

	shaders := make(map[string]backend.Shader, context.temp_allocator)
	for name, stages in uses {
		entries := make([dynamic]backend.ShaderEntryPoint, context.temp_allocator)
		if .Graphics in stages do append(&entries, ..GRAPHICS_ENTRIES)
		if .Compute in stages do append(&entries, ..COMPUTE_ENTRIES)
		shaders[name] = shader_load(engine, name, entries[:]) or_return
	}

	for spec, kind in PIPELINE_SPECS {
		reg.shaders[kind] = shaders[spec.shader]
		reg.pipelines[kind] = pipeline_build(engine, kind)
	}
	return true
}

@(private = "file")
pipeline_build :: proc(engine: ^Engine, kind: PipelineKind) -> backend.Pipeline {
	spec := PIPELINE_SPECS[kind]
	shader := engine.pipeline_registry.shaders[kind]
	switch spec.stage {
	case .Graphics:
		stages := [2]backend.ShaderStageDesc {
			{shader = shader, entry = VERTEX_ENTRY},
			{shader = shader, entry = FRAGMENT_MAIN},
		}
		desc := graphics_pipeline_desc(&engine.vk_ctx, spec)
		return backend.pipeline_create(&engine.vk_ctx, desc, stages[:])
	case .Compute:
		return backend.pipeline_create_compute(&engine.vk_ctx, {shader = shader, entry = COMPUTE_MAIN})
	}
	unreachable()
}

pipeline_get :: #force_inline proc(engine: ^Engine, kind: PipelineKind) -> backend.Pipeline {
	return engine.pipeline_registry.pipelines[kind]
}

// Recreates every pipeline that uses shader (after it was reloaded). backend.pipeline_destroy defers
// the old ones until frames in flight are done with them. Returns whether any shadow pipeline was
// rebuilt, since cached shadow maps then need re-rendering.
pipelines_rebuild_for_shader :: proc(engine: ^Engine, shader: backend.Shader) -> (shadow_rebuilt: bool) {
	reg := &engine.pipeline_registry
	for kind in PipelineKind {
		if reg.shaders[kind] != shader do continue
		backend.pipeline_destroy(&engine.vk_ctx, reg.pipelines[kind])
		reg.pipelines[kind] = pipeline_build(engine, kind)
		if kind == .Shadow || kind == .Shadow_Directional do shadow_rebuilt = true
		log.infof("Rebuilt pipeline: %v", kind)
	}
	return
}

pipelines_destroy :: proc(engine: ^Engine) {
	for pipeline in engine.pipeline_registry.pipelines do backend.pipeline_destroy(&engine.vk_ctx, pipeline)
}

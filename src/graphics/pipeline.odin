package graphics

import "core:log"

import "backend"

GraphicsPipelineKind :: enum u8 {
	Shadow, // spot + point lights
	Shadow_Directional, // directional cascades, depth-clamped
	Mesh, // opaque and mask
	Mesh_Transparent, // alpha blended, no depth write
	Skybox,
	UI,
	Particle,
	Debug_View,
	Debug_Line,
	Debug_Line_Overlay,
	Debug_Sector,
}

ComputePipelineKind :: enum u8 {
	Particle,
	Tonemap,
	Bloom_Down,
	Bloom_Up,
}

// A pipeline replaced by a hot reload, kept alive until no frame in flight can still use it.
RetiredPipeline :: struct {
	pipeline:    backend.Pipeline,
	frame_index: u64, // ctx.frame_index when it was replaced
}

PipelineRegistry :: struct {
	graphics:         [GraphicsPipelineKind]backend.Pipeline,
	compute:          [ComputePipelineKind]backend.Pipeline,
	graphics_shaders: [GraphicsPipelineKind]backend.Shader,
	compute_shaders:  [ComputePipelineKind]backend.Shader,
	retired:          [dynamic]RetiredPipeline,
}

// Loads every shader module the tables name (once each, with the entry points its pipelines need)
// and creates every pipeline. Depends only on the device: layouts come from format constants.
pipelines_create :: proc(engine: ^Engine) -> (ok: bool) {
	reg := &engine.pipeline_registry

	// Entry points per module: graphics pipelines need vertex + fragment, compute ones need compute.
	ModuleUse :: struct {
		graphics, compute: bool,
	}
	uses := make(map[string]ModuleUse, context.temp_allocator)
	for spec in GRAPHICS_PIPELINES {
		use := uses[spec.shader]
		use.graphics = true
		uses[spec.shader] = use
	}
	for spec in COMPUTE_PIPELINES {
		use := uses[spec.shader]
		use.compute = true
		uses[spec.shader] = use
	}

	shaders := make(map[string]backend.Shader, context.temp_allocator)
	for name, use in uses {
		entries := make([dynamic]backend.ShaderEntryPoint, context.temp_allocator)
		if use.graphics do append(&entries, ..GRAPHICS_ENTRIES)
		if use.compute do append(&entries, ..COMPUTE_ENTRIES)
		shaders[name] = shader_load(engine, name, entries[:]) or_return
	}

	for spec, kind in GRAPHICS_PIPELINES {
		reg.graphics_shaders[kind] = shaders[spec.shader]
		reg.graphics[kind] = graphics_pipeline_create(engine, kind)
	}
	for spec, kind in COMPUTE_PIPELINES {
		reg.compute_shaders[kind] = shaders[spec.shader]
		reg.compute[kind] = compute_pipeline_create(engine, kind)
	}
	return true
}

@(private = "file")
graphics_pipeline_create :: proc(engine: ^Engine, kind: GraphicsPipelineKind) -> backend.Pipeline {
	shader := engine.pipeline_registry.graphics_shaders[kind]
	stages := [2]backend.ShaderStageDesc {
		{shader = shader, entry = VERTEX_ENTRY},
		{shader = shader, entry = FRAGMENT_MAIN},
	}
	desc := graphics_pipeline_desc(&engine.vk_ctx, GRAPHICS_PIPELINES[kind])
	return backend.pipeline_create(&engine.vk_ctx, desc, stages[:])
}

@(private = "file")
compute_pipeline_create :: proc(engine: ^Engine, kind: ComputePipelineKind) -> backend.Pipeline {
	shader := engine.pipeline_registry.compute_shaders[kind]
	return backend.pipeline_create_compute(&engine.vk_ctx, {shader = shader, entry = COMPUTE_MAIN})
}

graphics_pipeline :: #force_inline proc(engine: ^Engine, kind: GraphicsPipelineKind) -> backend.Pipeline {
	return engine.pipeline_registry.graphics[kind]
}

compute_pipeline :: #force_inline proc(engine: ^Engine, kind: ComputePipelineKind) -> backend.Pipeline {
	return engine.pipeline_registry.compute[kind]
}

// Recreates every pipeline that uses shader (after it was reloaded). The old ones are retired, not
// destroyed: frames in flight may still be using them. Returns whether any shadow pipeline was
// rebuilt, since cached shadow maps then need re-rendering.
pipelines_rebuild_for_shader :: proc(engine: ^Engine, shader: backend.Shader) -> (shadow_rebuilt: bool) {
	reg := &engine.pipeline_registry
	frame := engine.vk_ctx.frame_index
	for kind in GraphicsPipelineKind {
		if reg.graphics_shaders[kind] != shader do continue
		append(&reg.retired, RetiredPipeline{pipeline = reg.graphics[kind], frame_index = frame})
		reg.graphics[kind] = graphics_pipeline_create(engine, kind)
		if kind == .Shadow || kind == .Shadow_Directional do shadow_rebuilt = true
		log.infof("Rebuilt graphics pipeline: %v", kind)
	}
	for kind in ComputePipelineKind {
		if reg.compute_shaders[kind] != shader do continue
		append(&reg.retired, RetiredPipeline{pipeline = reg.compute[kind], frame_index = frame})
		reg.compute[kind] = compute_pipeline_create(engine, kind)
		log.infof("Rebuilt compute pipeline: %v", kind)
	}
	return
}

// Destroys retired pipelines that every frame in flight has finished with. Call after frame_begin.
pipelines_collect_retired :: proc(engine: ^Engine) {
	reg := &engine.pipeline_registry
	#reverse for retired, i in reg.retired {
		if engine.vk_ctx.frame_index >= retired.frame_index + backend.MAX_FRAMES_IN_FLIGHT {
			backend.pipeline_destroy(&engine.vk_ctx, retired.pipeline)
			unordered_remove(&reg.retired, i)
		}
	}
}

// Expects the device to be idle.
pipelines_destroy :: proc(engine: ^Engine) {
	reg := &engine.pipeline_registry
	for retired in reg.retired do backend.pipeline_destroy(&engine.vk_ctx, retired.pipeline)
	delete(reg.retired)
	for pipeline in reg.graphics do backend.pipeline_destroy(&engine.vk_ctx, pipeline)
	for pipeline in reg.compute do backend.pipeline_destroy(&engine.vk_ctx, pipeline)
}

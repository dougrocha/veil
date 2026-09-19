#+build darwin

package backend

import "core:log"

import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"

ShaderModule :: distinct ^MTL.Library

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

shader_stage_function :: proc(desc: ShaderStageDesc) -> ^MTL.Function {
	name := NS.String_alloc()->initWithOdinString(string(desc.entry))
	fn := (^MTL.Library)(desc.module)->newFunctionWithName(name)
	if fn == nil {
		log.errorf("Metal: no function named '%s' in shader module", desc.entry)
	}
	return fn
}

shader_module_create :: proc(ctx: ^Context, source: string) -> ShaderModule {
	src := NS.String_alloc()->initWithOdinString(source)
	library, err := ctx.device->newLibraryWithSource(src, nil)
	if err != nil {
		log.errorf("Metal shader compile error: %s", err->localizedDescription()->odinString())
	}
	if library == nil {
		log.errorf("Metal shader source:\n%s", source)
	}
	return ShaderModule(library)
}

shader_module_destroy :: proc(ctx: ^Context, module: ShaderModule) {
	(^MTL.Library)(module)->release()
}

package backend

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import vk "vendor:vulkan"

import "../../handles"

// Handle to a backend-owned shader: compiled code plus the entry points it declares.
// The zero value means "no shader".
Shader :: handles.Handle(ShaderSlot)

MAX_SHADERS :: 256

ShaderStage :: enum u8 {
	Vertex,
	Fragment,
	Compute,
}

// The code format shader_create expects. The compiler asks for this instead of assuming it.
ShaderTarget :: enum {
	SPIRV,
}

ShaderEntryPoint :: struct {
	name:  string,
	stage: ShaderStage,
}

ShaderDesc :: struct {
	code:         []byte, // compiled for shader_target(ctx)
	entry_points: []ShaderEntryPoint,
}

// One pipeline stage: an entry point of a shader. The stage comes from the shader's desc.
ShaderStageDesc :: struct {
	shader: Shader,
	entry:  string,
}

@(private)
ShaderSlot :: struct {
	module:       vk.ShaderModule,
	entry_points: []ShaderEntryPoint, // owned copies of the desc's
}

shader_target :: proc(ctx: ^Context) -> ShaderTarget {
	return .SPIRV
}

shaders_init :: proc(ctx: ^Context, allocator: mem.Allocator) {
	ctx.shaders = handles.pool_init(MAX_SHADERS, ShaderSlot, allocator)
}

shaders_destroy :: proc(ctx: ^Context) {
	assert(handles.pool_live_count(&ctx.shaders) == 0, "shaders_destroy: shaders still alive")
}

shader_create :: proc(ctx: ^Context, desc: ShaderDesc) -> Shader {
	return handles.pool_alloc(&ctx.shaders, shader_slot_make(ctx, desc))
}

// Swaps in new code under the same handle (hot reload). Pipelines built from the old code
// keep working; rebuild them to pick up the new one.
shader_replace :: proc(ctx: ^Context, shader: Shader, desc: ShaderDesc, loc := #caller_location) {
	slot := handles.pool_get_live(&ctx.shaders, shader, loc)
	release_deferred(ctx, slot^)
	slot^ = shader_slot_make(ctx, desc)
}

shader_destroy :: proc(ctx: ^Context, shader: Shader, loc := #caller_location) {
	release_deferred(ctx, handles.pool_get_live(&ctx.shaders, shader, loc)^)
	handles.pool_free(&ctx.shaders, shader)
}

@(private = "file")
shader_slot_make :: proc(ctx: ^Context, desc: ShaderDesc) -> ShaderSlot {
	assert(len(desc.code) % size_of(u32) == 0, "shader_create: SPIR-V size is not a multiple of 4")
	assert(uintptr(raw_data(desc.code)) % align_of(u32) == 0, "shader_create: SPIR-V is not u32-aligned")
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(desc.code),
		pCode    = ([^]u32)(raw_data(desc.code)),
	}
	slot: ShaderSlot
	vk_check(vk.CreateShaderModule(ctx.device, &info, nil, &slot.module))

	slot.entry_points = slice.clone(desc.entry_points)
	for &entry in slot.entry_points {
		entry.name = strings.clone(entry.name)
	}
	return slot
}

@(private)
shader_slot_release :: proc(ctx: ^Context, slot: ShaderSlot) {
	vk.DestroyShaderModule(ctx.device, slot.module, nil)
	for entry in slot.entry_points do delete(entry.name)
	delete(slot.entry_points)
}

@(private)
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

// Resolves the entry point by name; panics if the shader doesn't declare it.
@(private)
shader_stage_info :: proc(
	ctx: ^Context,
	desc: ShaderStageDesc,
	loc := #caller_location,
) -> (
	vk.PipelineShaderStageCreateInfo,
	ShaderStage,
) {
	slot := handles.pool_get_live(&ctx.shaders, desc.shader, loc)
	for entry in slot.entry_points {
		if entry.name != desc.entry do continue
		info := vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = shader_stage_to_vk(entry.stage),
			module = slot.module,
			pName  = strings.clone_to_cstring(entry.name, context.temp_allocator),
		}
		return info, entry.stage
	}
	panic(fmt.tprintf("shader has no entry point %q", desc.entry))
}

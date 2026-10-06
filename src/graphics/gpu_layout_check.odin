package graphics

import "core:log"
import "core:reflect"
import "core:strings"

import "backend"
import sp "shared:odin-slang/slang"

// Asks Slang how it actually laid out each shared struct a compiled module uses, and compares that
// with Odin's layout. gpu_layout_generated.odin asserts the layout the generator expects; this
// catches the generator's model of Slang being wrong. Off in release builds, with the validation
// layers.
GPU_LAYOUT_CHECK :: backend.VEIL_VALIDATION

// A gpu_types.odin struct and the name the generator gives it in Slang.
GpuSharedType :: struct {
	slang_name: string,
	type:       typeid,
}

// Walks the module's global parameters (push constants) down through constant buffers, pointers,
// arrays and struct fields, checking every shared struct it reaches. Logs each mismatch; false if
// any.
gpu_layout_check :: proc(layout: ^sp.ProgramLayout, module_name: string) -> bool {
	visited := make(map[string]struct{}, allocator = context.temp_allocator)
	ok := true
	for i in 0 ..< sp.Reflection_GetParameterCount(layout) {
		param := sp.Reflection_GetParameterByIndex(layout, i)
		ok &= check_type_layout(sp.variable_layout_getTypeLayout(param), module_name, &visited)
	}
	return ok
}

@(private = "file")
check_type_layout :: proc(
	type_layout: ^sp.TypeLayoutReflection,
	module_name: string,
	visited: ^map[string]struct{},
) -> bool {
	if type_layout == nil do return true
	#partial switch sp.type_layout_getKind(type_layout) {
	case .Struct:
		name := strings.clone_from(sp.type_layout_getName(type_layout), context.temp_allocator)
		if name in visited do return true
		visited[name] = {}
		ok := check_struct(type_layout, name, module_name)
		for i in 0 ..< sp.type_layout_getFieldCount(type_layout) {
			field := sp.type_layout_getFieldByIndex(type_layout, i)
			ok &= check_type_layout(sp.variable_layout_getTypeLayout(field), module_name, visited)
		}
		return ok
	case .Array, .Pointer, .ConstantBuffer, .ParameterBlock, .ShaderStorageBuffer, .TextureBuffer:
		return check_type_layout(sp.type_layout_getElementTypeLayout(type_layout), module_name, visited)
	}
	return true
}

// Shader-local structs (VSOutput, ...) aren't shared and pass. A shared struct passes when every
// Slang field exists in Odin at the same offset and Odin's size matches Slang's stride. Stride, not
// size: Slang's scalar layout ends a struct at its last field (a push constant block of three
// pointers and a float is 28 bytes), while its stride, like Odin's size, rounds up to the alignment.
// Fields Slang doesn't have, such as the _pad after a Vec3 the generator folds into a float4,
// aren't checked.
@(private = "file")
check_struct :: proc(type_layout: ^sp.TypeLayoutReflection, name, module_name: string) -> bool {
	odin_type: typeid
	for shared in GPU_SHARED_TYPES do if shared.slang_name == name do odin_type = shared.type
	if odin_type == nil do return true

	ok := true
	for i in 0 ..< sp.type_layout_getFieldCount(type_layout) {
		field := sp.type_layout_getFieldByIndex(type_layout, i)
		field_name := string(sp.variable_layout_getName(field))
		slang_offset := uintptr(sp.variable_layout_getOffset(field, .Uniform))
		odin_field := reflect.struct_field_by_name(odin_type, field_name)
		switch {
		case odin_field.type == nil:
			log.errorf("%s: %v has no field %s that Slang's %s has", module_name, odin_type, field_name, name)
			ok = false
		case odin_field.offset != slang_offset:
			log.errorf(
				"%s: %v.%s is at offset %d in Odin but %d in Slang",
				module_name,
				odin_type,
				field_name,
				odin_field.offset,
				slang_offset,
			)
			ok = false
		}
	}
	slang_stride := int(sp.type_layout_getStride(type_layout, .Uniform))
	if odin_size := size_of_typeid(odin_type); odin_size != slang_stride {
		log.errorf(
			"%s: %v is %d bytes in Odin but has a %d byte stride in Slang",
			module_name,
			odin_type,
			odin_size,
			slang_stride,
		)
		ok = false
	}
	return ok
}

@(private = "file")
size_of_typeid :: proc(t: typeid) -> int {
	return type_info_of(t).size
}

package main

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strings"

import gfx "veil:graphics"

Spec :: struct {
	odin_name: string,
	expr: ^ast.Struct_Type,
}

Const_Spec :: struct { name: string, expr: ^ast.Expr }

fail :: proc(message: string) -> ! {
	fmt.eprintln(message)
	os.exit(1)
}

collect_specs :: proc(constants: ^[dynamic]Const_Spec) -> [dynamic]Spec {
	src, err := os.read_entire_file("src/graphics/gpu_types.odin", context.temp_allocator)
	if err != nil do fail("could not read src/graphics/gpu_types.odin")
	file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
	file.src = string(src)
	file.fullpath, _ = filepath.abs("src/graphics/gpu_types.odin", context.temp_allocator)
	p := parser.default_parser()
	if !parser.parse_file(&p, file) do fail("could not parse gpu_types.odin")

	specs: [dynamic]Spec
	for decl in file.decls {
		value, ok := decl.derived_stmt.(^ast.Value_Decl)
		if !ok || len(value.names) != 1 || len(value.values) != 1 do continue
		ident, ident_ok := value.names[0].derived.(^ast.Ident)
		if !ident_ok do continue
		if _, struct_ok := value.values[0].derived_expr.(^ast.Struct_Type); struct_ok {
			append(&specs, Spec{ident.name, value.values[0].derived_expr.(^ast.Struct_Type)})
		} else {
			append(constants, Const_Spec{ident.name, value.values[0]})
		}
	}
	if len(specs) == 0 do fail("gpu_types.odin contains no structs")
	return specs
}

write_const_expr :: proc(builder: ^strings.Builder, expr: ^ast.Expr) {
	#partial switch node in expr.derived {
	case ^ast.Basic_Lit: strings.write_string(builder, node.tok.text)
	case ^ast.Ident: strings.write_string(builder, node.name)
	case ^ast.Binary_Expr:
		strings.write_string(builder, "("); write_const_expr(builder, node.left)
		fmt.sbprintf(builder, " %s ", node.op.text); write_const_expr(builder, node.right)
		strings.write_string(builder, ")")
	case ^ast.Paren_Expr:
		strings.write_string(builder, "("); write_const_expr(builder, node.expr); strings.write_string(builder, ")")
	case: fail("GPU constants must use literals, names, and arithmetic")
	}
}

slang_name :: proc(name: string) -> string {
	return name[3:] if strings.has_prefix(name, "Gpu") else name
}

write_ast_type :: proc(builder: ^strings.Builder, expr: ^ast.Expr) {
	#partial switch node in expr.derived {
	case ^ast.Ident:
		switch node.name {
		case "Vec2": strings.write_string(builder, "float2")
		case "Vec3": strings.write_string(builder, "float3")
		case "Vec4": strings.write_string(builder, "float4")
		case "Mat4x4": strings.write_string(builder, "float4x4")
		case "f32": strings.write_string(builder, "float")
		case "u32": strings.write_string(builder, "uint")
		case: strings.write_string(builder, slang_name(node.name))
		}
	case ^ast.Array_Type:
		write_ast_type(builder, node.elem)
	case:
		fail("unsupported field type in gpu_types.odin")
	}
}

write_ast_array_suffix :: proc(builder: ^strings.Builder, expr: ^ast.Expr) {
	#partial switch node in expr.derived {
	case ^ast.Array_Type:
		if _, ok := node.elem.derived.(^ast.Array_Type); ok {
			write_ast_array_suffix(builder, node.elem)
		}
		#partial switch length in node.len.derived_expr {
		case ^ast.Basic_Lit: fmt.sbprintf(builder, "[%s]", length.tok.text)
		case ^ast.Ident: fmt.sbprintf(builder, "[%s]", length.name)
		case: fail("GPU array lengths require constants")
		}
	}
}

base_type :: proc(info: ^runtime.Type_Info) -> ^runtime.Type_Info {
	info := info
	for {
		if named, ok := info.variant.(runtime.Type_Info_Named); ok {
			info = named.base
		} else {
			return info
		}
	}
}

named_type :: proc(info: ^runtime.Type_Info) -> (runtime.Type_Info_Named, bool) {
	if named, ok := info.variant.(runtime.Type_Info_Named); ok do return named, true
	return {}, false
}

slang_struct_name :: proc(name: string) -> string {
	if strings.has_prefix(name, "Gpu") do return name[3:]
	return name
}

write_type :: proc(builder: ^strings.Builder, info: ^runtime.Type_Info) {
	info := info
	if named, ok := named_type(info); ok {
		switch named.name {
		case "Vec2":   strings.write_string(builder, "float2"); return
		case "Vec3":   strings.write_string(builder, "float3"); return
		case "Vec4":   strings.write_string(builder, "float4"); return
		case "Mat4x4": strings.write_string(builder, "float4x4"); return
		}
		if _, ok := base_type(info).variant.(runtime.Type_Info_Struct); ok {
			strings.write_string(builder, slang_struct_name(named.name))
			return
		}
		info = named.base
	}

	#partial switch value in info.variant {
	case runtime.Type_Info_Float:
		if info.size != 4 do fail("only f32 is supported in shared GPU types")
		strings.write_string(builder, "float")
	case runtime.Type_Info_Integer:
		if info.size != 4 do fail("only 32-bit integers are supported in shared GPU types")
		strings.write_string(builder, value.signed ? "int" : "uint")
	case runtime.Type_Info_Array:
		elem := base_type(value.elem)
		_, elem_is_float := elem.variant.(runtime.Type_Info_Float)
		if elem_is_float && elem.size == 4 && value.count >= 2 && value.count <= 4 {
			fmt.sbprintf(builder, "float%d", value.count)
		} else {
			write_type(builder, value.elem)
		}
	case runtime.Type_Info_Matrix:
		if value.row_count != 4 || value.column_count != 4 || value.elem.size != 4 {
			fail("only matrix[4, 4]f32 is supported in shared GPU types")
		}
		strings.write_string(builder, "float4x4")
	case runtime.Type_Info_Struct:
		fail("shared struct fields must use a named type")
	case:
		fail("unsupported field type in shared GPU type")
	}
}

write_array_suffix :: proc(builder: ^strings.Builder, info: ^runtime.Type_Info) {
	base := info
	if named, ok := named_type(base); ok do base = named.base
	if array, ok := base.variant.(runtime.Type_Info_Array); ok {
		elem := base_type(array.elem)
		_, elem_is_float := elem.variant.(runtime.Type_Info_Float)
		if elem_is_float && elem.size == 4 && array.count >= 2 && array.count <= 4 do return
		fmt.sbprintf(builder, "[%d]", array.count)
		write_array_suffix(builder, array.elem)
	}
}

is_vec3 :: proc(info: ^runtime.Type_Info) -> bool {
	base := base_type(info)
	array, ok := base.variant.(runtime.Type_Info_Array)
	if !ok || array.count != 3 do return false
	elem := base_type(array.elem)
	_, ok = elem.variant.(runtime.Type_Info_Float)
	return ok && elem.size == 4
}

is_f32 :: proc(info: ^runtime.Type_Info) -> bool {
	base := base_type(info)
	_, ok := base.variant.(runtime.Type_Info_Float)
	return ok && base.size == 4
}

write_struct :: proc(builder: ^strings.Builder, spec: Spec) {
	fmt.sbprintf(builder, "struct %s ", slang_name(spec.odin_name))
	strings.write_string(builder, "{\n")
	for field_index := 0; field_index < len(spec.expr.fields.list); field_index += 1 {
		field := spec.expr.fields.list[field_index]
		field_name, ok := field.names[0].derived_expr.(^ast.Ident)
		if !ok do fail("GPU fields require simple names")
		strings.write_string(builder, "    ")
		collapse_vec3 := false
		if field_index + 1 < len(spec.expr.fields.list) {
			next := spec.expr.fields.list[field_index + 1]
			next_name, next_name_ok := next.names[0].derived_expr.(^ast.Ident)
			field_ident, field_ident_ok := field.type.derived.(^ast.Ident)
			next_ident, next_ident_ok := next.type.derived.(^ast.Ident)
			collapse_vec3 = field_ident_ok && next_ident_ok && next_name_ok && field_ident.name == "Vec3" && next_ident.name == "f32" && strings.has_prefix(next_name.name, "_pad")
		}
		if collapse_vec3 {
			strings.write_string(builder, "float4")
			field_index += 1
		} else {
			write_ast_type(builder, field.type)
		}
		fmt.sbprintf(builder, " %s", field_name.name)
		write_ast_array_suffix(builder, field.type)
		strings.write_string(builder, ";\n")
	}
	strings.write_string(builder, "};\n\n")
}

main :: proc() {
	constants: [dynamic]Const_Spec
	specs := collect_specs(&constants)
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, "// Generated from src/graphics/gpu_types.odin. Do not edit.\n\n")
	for constant in constants {
		fmt.sbprintf(&builder, "static const uint %s = ", constant.name)
		write_const_expr(&builder, constant.expr)
		strings.write_string(&builder, ";\n")
	}
	strings.write_string(&builder, "\n")

	for spec in specs do write_struct(&builder, spec)
	fmt.println(strings.trim_right(strings.to_string(builder), "\n"))
}

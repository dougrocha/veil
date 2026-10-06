package main

// Collects every declaration tagged @(shader_shared) in src/graphics and writes:
// - shaders/types.slang: its constants, enums, handle types and structs, in Slang;
// - src/graphics/gpu_layout_generated.odin: #asserts holding each struct's field offsets and size
//   to the layout Slang gives them, and the Slang name -> Odin type table gpu_layout_check uses.
//
// `gpu_types_gen --check` writes nothing and fails when either file is stale.
//
// What can be shared:
// - constants (integer arithmetic over literals and other shared constants);
// - `enum u32` types, emitted as NAME_VARIANT constants;
// - handle types, `distinct u32`, emitted as `struct Name { uint value; }` (bindless.slang and
//   storage.slang give them a get());
// - structs marked #max_field_align(16), of f32, u32, i32, Vec2/3/4, Mat4x4, [4]u8 (a packed
//   RGBA8 uint), fixed arrays, backend.GPUPtr(T) (a T*) and other shared types.
//
// Layout: Slang compiles with scalar layout (GLSLForceScalarLayout in shaders.odin): scalars,
// vectors and matrices align to 4, pointers to 8, and structs lay out like C. A struct's size here
// is its stride, rounded up to its alignment like Odin's size_of. gpu_layout_check verifies this
// model against Slang's own reflection when shaders compile.
//
// Every field must also sit where std430 and Metal would put it, so the same structs work on any
// backend: Vec2 on 8 bytes, Vec3/Vec4/Mat4x4 on 16, pointers on 8, and a struct used in arrays
// (anything but push constants) must be a multiple of its alignment in size.
//
// TODO: when a second backend lands, model each target's layout rules (Metal pads float3 in
// structs, D3D constant buffers can't straddle 16 bytes) and check every struct against all of
// them, and give backend.GPUPtr fields a portable form: D3D12 shaders have no raw pointers.
// TODO: once entities grow subtypes, read @(entity) tags here too and generate the entity kind enum
// and subtype registration, as rivet's metaprogram does.

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode"

SOURCE_GLOB :: "src/graphics/*.odin"
SLANG_OUTPUT :: "shaders/types.slang"
ODIN_OUTPUT :: "src/graphics/gpu_layout_generated.odin"
TAG :: "shader_shared"

// Vulkan guarantees at least this many bytes of push constants.
MAX_PUSH_CONSTANTS_SIZE :: 128

// Bare u32 fields with these suffixes must use the typed handle instead.
HANDLE_SUFFIXES :: [?]struct {
	suffix, type: string,
}{{"_texture", "TextureIndex"}, {"_cube", "CubeIndex"}, {"_storage", "StorageImageIndex"}}

Decl :: struct {
	name: string,
	pos:  tokenizer.Pos,
	expr: ^ast.Expr,
}

Specs :: struct {
	constants: [dynamic]Decl,
	enums:     [dynamic]Decl, // expr is ^ast.Enum_Type
	handles:   [dynamic]Decl, // expr is the ^ast.Distinct_Type
	structs:   [dynamic]Decl, // expr is ^ast.Struct_Type
	layouts:   map[string]Struct_Layout, // filled lazily by struct_layout
}

Layout :: struct {
	size, align: int,
	portable:    int, // the alignment std430 and Metal need
}

Struct_Layout :: struct {
	using layout: Layout,
	offsets:      []int, // per field, in declaration order
}

fail :: proc(message: string, args: ..any) -> ! {
	fmt.eprintfln(message, ..args)
	os.exit(1)
}

// Reports at a source position in the compiler's format, so editors can jump to it.
fail_at :: proc(pos: tokenizer.Pos, message: string, args: ..any) -> ! {
	fmt.eprintf("%s(%d:%d) Error: ", pos.file, pos.line, pos.column)
	fmt.eprintfln(message, ..args)
	os.exit(1)
}

has_tag :: proc(value: ^ast.Value_Decl) -> bool {
	for attribute in value.attributes {
		for elem in attribute.elems {
			if ident, ok := elem.derived.(^ast.Ident); ok && ident.name == TAG do return true
		}
	}
	return false
}

collect_specs :: proc() -> (specs: Specs) {
	paths, err := filepath.glob(SOURCE_GLOB)
	if err != nil do fail("could not list %s", SOURCE_GLOB)
	slice.sort(paths)
	for path in paths {
		if path == ODIN_OUTPUT do continue
		src, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil do fail("could not read %s", path)
		file := ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
		file.src = string(src)
		file.fullpath = path
		p := parser.default_parser()
		if !parser.parse_file(&p, file) do fail("could not parse %s", path)

		for decl in file.decls {
			value, ok := decl.derived_stmt.(^ast.Value_Decl)
			if !ok || !has_tag(value) do continue
			if len(value.names) != 1 || len(value.values) != 1 {
				fail_at(value.pos, "@(%s) needs exactly one name and one value", TAG)
			}
			ident, ident_ok := value.names[0].derived.(^ast.Ident)
			if !ident_ok do fail_at(value.pos, "@(%s) needs a plain name", TAG)
			d := Decl{ident.name, value.pos, value.values[0]}
			#partial switch type in value.values[0].derived_expr {
			case ^ast.Struct_Type:
				append(&specs.structs, d)
			case ^ast.Enum_Type:
				base: ^ast.Ident
				if type.base_type != nil do base, _ = type.base_type.derived.(^ast.Ident)
				if base == nil || base.name != "u32" {
					fail_at(value.pos, "shared enum %s must be `enum u32`", ident.name)
				}
				append(&specs.enums, d)
			case ^ast.Distinct_Type:
				base, base_ok := type.type.derived.(^ast.Ident)
				if !base_ok || base.name != "u32" {
					fail_at(value.pos, "shared handle %s must be `distinct u32`", ident.name)
				}
				append(&specs.handles, d)
			case:
				append(&specs.constants, d)
			}
		}
	}
	if len(specs.structs) == 0 do fail("no struct in %s is tagged @(%s)", SOURCE_GLOB, TAG)
	return
}

find :: proc(decls: []Decl, name: string) -> (Decl, bool) {
	for d in decls do if d.name == name do return d, true
	return {}, false
}

// The T of backend.GPUPtr(T), or nil when expr isn't a GPU pointer.
pointee :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	call, ok := expr.derived.(^ast.Call_Expr)
	if !ok || len(call.args) != 1 do return nil
	name: string
	#partial switch callee in call.expr.derived {
	case ^ast.Selector_Expr:
		name = callee.field.name
	case ^ast.Ident:
		name = callee.name
	}
	return call.args[0] if name == "GPUPtr" else nil
}

// [4]u8: a packed RGBA8 color, a uint on the GPU.
is_packed_color :: proc(expr: ^ast.Expr) -> bool {
	array, ok := expr.derived.(^ast.Array_Type)
	if !ok || array.len == nil do return false
	elem, elem_ok := array.elem.derived.(^ast.Ident)
	count, count_ok := array.len.derived.(^ast.Basic_Lit)
	return elem_ok && count_ok && elem.name == "u8" && count.tok.text == "4"
}

eval_const :: proc(specs: ^Specs, expr: ^ast.Expr) -> int {
	#partial switch node in expr.derived {
	case ^ast.Basic_Lit:
		value, ok := strconv.parse_int(node.tok.text)
		if !ok do fail_at(node.pos, "not an integer constant: %s", node.tok.text)
		return value
	case ^ast.Ident:
		c, ok := find(specs.constants[:], node.name)
		if !ok do fail_at(node.pos, "%s is used by shared code but isn't tagged @(%s)", node.name, TAG)
		return eval_const(specs, c.expr)
	case ^ast.Paren_Expr:
		return eval_const(specs, node.expr)
	case ^ast.Binary_Expr:
		a, b := eval_const(specs, node.left), eval_const(specs, node.right)
		switch node.op.text {
		case "+":
			return a + b
		case "-":
			return a - b
		case "*":
			return a * b
		case "/":
			return a / b
		}
		fail_at(node.pos, "unsupported operator %s in a shared constant", node.op.text)
	}
	fail_at(expr.pos, "shared constants must use literals, names, and arithmetic")
}

round_up :: proc(n, align: int) -> int {
	return (n + align - 1) / align * align
}

type_layout :: proc(specs: ^Specs, expr: ^ast.Expr) -> Layout {
	if pointee(expr) != nil do return {8, 8, 8}
	if is_packed_color(expr) do return {4, 4, 4}
	#partial switch node in expr.derived {
	case ^ast.Ident:
		switch node.name {
		case "f32", "u32", "i32":
			return {4, 4, 4}
		case "Vec2":
			return {8, 4, 8}
		case "Vec3":
			return {12, 4, 16}
		case "Vec4":
			return {16, 4, 16}
		case "Mat4x4":
			return {64, 4, 16}
		}
		if _, ok := find(specs.enums[:], node.name); ok do return {4, 4, 4}
		if _, ok := find(specs.handles[:], node.name); ok do return {4, 4, 4}
		if s, ok := find(specs.structs[:], node.name); ok do return struct_layout(specs, s).layout
		fail_at(node.pos, "%s isn't a GPU type: tag it @(%s) or use a supported type", node.name, TAG)
	case ^ast.Array_Type:
		if node.len == nil do fail_at(node.pos, "shared arrays need a fixed length")
		elem := type_layout(specs, node.elem)
		return {eval_const(specs, node.len) * round_up(elem.size, elem.align), elem.align, elem.portable}
	}
	fail_at(expr.pos, "unsupported field type in a shared struct")
}

type_name :: proc(expr: ^ast.Expr) -> string {
	if ident, ok := expr.derived.(^ast.Ident); ok do return ident.name
	return "this type"
}

field_name :: proc(field: ^ast.Field) -> string {
	ident, ok := field.names[0].derived_expr.(^ast.Ident)
	if !ok do fail_at(field.pos, "shared fields need plain names")
	return ident.name
}

struct_layout :: proc(specs: ^Specs, decl: Decl) -> Struct_Layout {
	if cached, ok := specs.layouts[decl.name]; ok do return cached
	type := decl.expr.derived.(^ast.Struct_Type)
	check_struct_attributes(decl, type)

	result := Struct_Layout {
		layout  = {0, 1, 4},
		offsets = make([]int, len(type.fields.list)),
	}
	for field, i in type.fields.list {
		if len(field.names) != 1 do fail_at(field.pos, "%s: declare one shared field per line", decl.name)
		name := field_name(field)
		check_handle_field(field, name)
		field_layout := type_layout(specs, field.type)
		offset := round_up(result.size, field_layout.align)
		if offset % field_layout.portable != 0 {
			fail_at(
				field.pos,
				"%s.%s (%s) is at offset %d, but std430 and Metal put it on a %d-byte boundary\n\tSuggestion: reorder the fields, or add _pad fields before it",
				decl.name,
				name,
				type_name(field.type),
				offset,
				field_layout.portable,
			)
		}
		result.offsets[i] = offset
		result.size = offset + field_layout.size
		result.align = max(result.align, field_layout.align)
		result.portable = max(result.portable, field_layout.portable)
	}
	result.size = round_up(result.size, result.align)
	is_push_constants := strings.has_suffix(decl.name, "PushConstants")
	if !is_push_constants && result.size % result.portable != 0 {
		fail_at(
			decl.pos,
			"%s is %d bytes, not a multiple of its %d-byte alignment, so arrays of it differ between targets\n\tSuggestion: add _pad fields to reach %d bytes",
			decl.name,
			result.size,
			result.portable,
			round_up(result.size, result.portable),
		)
	}
	if is_push_constants && result.size > MAX_PUSH_CONSTANTS_SIZE {
		fail_at(
			decl.pos,
			"%s is %d bytes, over the %d push constant budget",
			decl.name,
			result.size,
			MAX_PUSH_CONSTANTS_SIZE,
		)
	}
	specs.layouts[decl.name] = result
	return result
}

check_struct_attributes :: proc(decl: Decl, type: ^ast.Struct_Type) {
	// The parser keeps the directive's parentheses: #max_field_align(16) holds a Paren_Expr.
	max_align: ^ast.Basic_Lit
	expr := type.max_field_align
	for expr != nil {
		paren, is_paren := expr.derived.(^ast.Paren_Expr)
		if !is_paren do break
		expr = paren.expr
	}
	if expr != nil do max_align, _ = expr.derived.(^ast.Basic_Lit)
	if max_align == nil || max_align.tok.text != "16" {
		fail_at(
			decl.pos,
			"shared struct %s needs #max_field_align(16)\n\tSuggestion: %s :: struct #max_field_align(16) {{",
			decl.name,
			decl.name,
		)
	}
	if type.is_packed do fail_at(decl.pos, "shared struct %s can't be #packed", decl.name)
}

check_handle_field :: proc(field: ^ast.Field, name: string) {
	ident, ok := field.type.derived.(^ast.Ident)
	if !ok || ident.name != "u32" do return
	for h in HANDLE_SUFFIXES {
		if strings.has_suffix(name, h.suffix) {
			fail_at(
				field.pos,
				"%s is a bindless slot; use %s instead of u32\n\tSuggestion: %s: %s,",
				name,
				h.type,
				name,
				h.type,
			)
		}
	}
}

slang_name :: proc(name: string) -> string {
	return name[3:] if strings.has_prefix(name, "Gpu") else name
}

write_slang_type :: proc(b: ^strings.Builder, specs: ^Specs, expr: ^ast.Expr) {
	if target := pointee(expr); target != nil {
		write_slang_type(b, specs, target)
		strings.write_string(b, "*")
		return
	}
	if is_packed_color(expr) {
		strings.write_string(b, "uint")
		return
	}
	#partial switch node in expr.derived {
	case ^ast.Ident:
		switch node.name {
		case "Vec2":
			strings.write_string(b, "float2")
		case "Vec3":
			strings.write_string(b, "float3")
		case "Vec4":
			strings.write_string(b, "float4")
		case "Mat4x4":
			strings.write_string(b, "float4x4")
		case "f32":
			strings.write_string(b, "float")
		case "u32":
			strings.write_string(b, "uint")
		case "i32":
			strings.write_string(b, "int")
		case:
			_, is_enum := find(specs.enums[:], node.name)
			strings.write_string(b, "uint" if is_enum else slang_name(node.name))
		}
	case ^ast.Array_Type:
		write_slang_type(b, specs, node.elem)
	case:
		fail_at(expr.pos, "unsupported field type in a shared struct")
	}
}

write_slang_array_suffix :: proc(b: ^strings.Builder, expr: ^ast.Expr) {
	if is_packed_color(expr) do return
	node, ok := expr.derived.(^ast.Array_Type)
	if !ok do return
	write_slang_array_suffix(b, node.elem)
	#partial switch length in node.len.derived_expr {
	case ^ast.Basic_Lit:
		fmt.sbprintf(b, "[%s]", length.tok.text)
	case ^ast.Ident:
		fmt.sbprintf(b, "[%s]", length.name)
	case:
		fail_at(node.pos, "shared array lengths must be a literal or a shared constant")
	}
}

write_const_expr :: proc(b: ^strings.Builder, expr: ^ast.Expr) {
	#partial switch node in expr.derived {
	case ^ast.Basic_Lit:
		strings.write_string(b, node.tok.text)
	case ^ast.Ident:
		strings.write_string(b, node.name)
	case ^ast.Binary_Expr:
		strings.write_string(b, "(")
		write_const_expr(b, node.left)
		fmt.sbprintf(b, " %s ", node.op.text)
		write_const_expr(b, node.right)
		strings.write_string(b, ")")
	case ^ast.Paren_Expr:
		strings.write_string(b, "(")
		write_const_expr(b, node.expr)
		strings.write_string(b, ")")
	case:
		fail_at(expr.pos, "shared constants must use literals, names, and arithmetic")
	}
}

// LightType -> LIGHT_TYPE, Texture_2D -> TEXTURE_2D.
screaming :: proc(name: string) -> string {
	b := strings.builder_make()
	prev: rune
	for r, i in name {
		if i > 0 && unicode.is_upper(r) && unicode.is_lower(prev) do strings.write_byte(&b, '_')
		strings.write_rune(&b, unicode.to_upper(r))
		prev = r
	}
	return strings.to_string(b)
}

// The shared structs a field type mentions, so they can be emitted first.
struct_dependencies :: proc(specs: ^Specs, expr: ^ast.Expr, out: ^[dynamic]Decl) {
	if target := pointee(expr); target != nil {
		struct_dependencies(specs, target, out)
		return
	}
	#partial switch node in expr.derived {
	case ^ast.Ident:
		if s, ok := find(specs.structs[:], node.name); ok do append(out, s)
	case ^ast.Array_Type:
		struct_dependencies(specs, node.elem, out)
	}
}

write_slang_struct :: proc(b: ^strings.Builder, specs: ^Specs, decl: Decl, written: ^map[string]bool) {
	if written[decl.name] do return
	written[decl.name] = true
	type := decl.expr.derived.(^ast.Struct_Type)
	deps := make([dynamic]Decl, context.temp_allocator)
	for field in type.fields.list do struct_dependencies(specs, field.type, &deps)
	for dep in deps do write_slang_struct(b, specs, dep, written)

	fmt.sbprintf(b, "struct %s {{\n", slang_name(decl.name))
	fields := type.fields.list
	for i := 0; i < len(fields); i += 1 {
		field := fields[i]
		strings.write_string(b, "    ")
		// Vec3 followed by an f32 _pad field reads as one float4.
		collapse_vec3 := false
		if i + 1 < len(fields) {
			field_type, field_ok := field.type.derived.(^ast.Ident)
			next_type, next_ok := fields[i + 1].type.derived.(^ast.Ident)
			collapse_vec3 =
				field_ok &&
				next_ok &&
				field_type.name == "Vec3" &&
				next_type.name == "f32" &&
				strings.has_prefix(field_name(fields[i + 1]), "_pad")
		}
		if collapse_vec3 {
			strings.write_string(b, "float4")
		} else {
			write_slang_type(b, specs, field.type)
		}
		fmt.sbprintf(b, " %s", field_name(field))
		write_slang_array_suffix(b, field.type)
		strings.write_string(b, ";\n")
		if collapse_vec3 do i += 1
	}
	strings.write_string(b, "};\n\n")
}

slang_source :: proc(specs: ^Specs) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "// Generated from the @(shader_shared) declarations in src/graphics. Do not edit.\n\n")
	for constant in specs.constants {
		fmt.sbprintf(&b, "static const uint %s = ", constant.name)
		write_const_expr(&b, constant.expr)
		strings.write_string(&b, ";\n")
	}
	for e in specs.enums {
		strings.write_string(&b, "\n")
		value := 0
		for field in e.expr.derived.(^ast.Enum_Type).fields {
			name: string
			#partial switch node in field.derived {
			case ^ast.Ident:
				name = node.name
			case ^ast.Field_Value:
				name = node.field.derived.(^ast.Ident).name
				value = eval_const(specs, node.value)
			case:
				fail_at(field.pos, "enum %s: unsupported field", e.name)
			}
			fmt.sbprintf(&b, "static const uint %s_%s = %d;\n", screaming(e.name), screaming(name), value)
			value += 1
		}
	}
	strings.write_string(&b, "\n")
	for h in specs.handles do fmt.sbprintf(&b, "struct %s {{\n    uint value;\n}};\n\n", h.name)
	written := make(map[string]bool, context.temp_allocator)
	for s in specs.structs do write_slang_struct(&b, specs, s, &written)
	return fmt.tprintf("%s\n", strings.trim_right(strings.to_string(b), "\n"))
}

odin_source :: proc(specs: ^Specs) -> string {
	b := strings.builder_make()
	strings.write_string(
		&b,
		"// Generated from the @(shader_shared) declarations in src/graphics by tools/gpu_types_gen.\n",
	)
	strings.write_string(
		&b,
		"// Do not edit. Holds each struct to the scalar layout Slang compiles with (see shaders.odin).\n",
	)
	strings.write_string(&b, "package graphics\n")
	strings.write_string(&b, "\n// Every shared struct by its Slang name, for gpu_layout_check.\n")
	strings.write_string(&b, "GPU_SHARED_TYPES := [?]GpuSharedType {\n")
	for s in specs.structs do fmt.sbprintf(&b, "\t{{%q, %s}},\n", slang_name(s.name), s.name)
	strings.write_string(&b, "}\n")
	for s in specs.structs {
		layout := struct_layout(specs, s)
		strings.write_string(&b, "\n")
		for field, i in s.expr.derived.(^ast.Struct_Type).fields.list {
			fmt.sbprintf(&b, "#assert(offset_of(%s, %s) == %d)\n", s.name, field_name(field), layout.offsets[i])
		}
		fmt.sbprintf(&b, "#assert(size_of(%s) == %d)\n", s.name, layout.size)
	}
	return strings.to_string(b)
}

is_current :: proc(path, contents: string) -> bool {
	old, err := os.read_entire_file(path, context.allocator)
	return err == nil && string(old) == contents
}

// Writes only when the contents changed, so the outputs keep their timestamps otherwise.
update_file :: proc(path, contents: string) {
	if is_current(path, contents) do return
	if err := os.write_entire_file(path, transmute([]byte)contents); err != nil do fail("could not write %s", path)
}

main :: proc() {
	check := len(os.args) == 2 && os.args[1] == "--check"
	if len(os.args) > 1 && !check do fail("usage: gpu_types_gen [--check]")

	specs := collect_specs()
	slang, odin := slang_source(&specs), odin_source(&specs)
	if check {
		stale := false
		for out in ([?][2]string{{SLANG_OUTPUT, slang}, {ODIN_OUTPUT, odin}}) {
			if !is_current(out[0], out[1]) {
				fmt.eprintfln("%s is stale", out[0])
				stale = true
			}
		}
		if stale do fail("run `just gpu-types`")
		return
	}
	update_file(SLANG_OUTPUT, slang)
	update_file(ODIN_OUTPUT, odin)
}

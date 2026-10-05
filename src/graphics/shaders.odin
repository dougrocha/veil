package graphics

import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "../watcher"
import "backend"

import sp "shared:odin-slang/slang"

VERTEX_ENTRY :: "vertex_main"
FRAGMENT_MAIN :: "fragment_main"
COMPUTE_MAIN :: "compute_main"

// Entry point sets the shaders declare.
GRAPHICS_ENTRIES :: []backend.ShaderEntryPoint{{VERTEX_ENTRY, .Vertex}, {FRAGMENT_MAIN, .Fragment}}
COMPUTE_ENTRIES :: []backend.ShaderEntryPoint{{COMPUTE_MAIN, .Compute}}

log_slang_diagnostics :: proc(diagnostics: ^sp.IBlob, failed: bool) {
	if diagnostics == nil do return
	defer diagnostics->release()
	message := cstring(diagnostics->getBufferPointer())
	if failed {
		log.errorf("Slang: %s", message)
	} else {
		log.warnf("Slang: %s", message)
	}
}

ShaderSystem :: struct {
	global_session:         ^sp.IGlobalSession,
	// Slang's ISession caches loaded modules by name; reusing one session
	// across reloads makes loadModule return the stale cached module instead
	// of recompiling changed source, so shader_load creates a fresh session
	// per call instead of reusing a stored one.
	bindless_texture_count: u32,
	loaded:                 map[string]LoadedShader, // by module name
	fw:                     watcher.Watcher,
}

// What a module was loaded with, so a reload can recompile it the same way.
LoadedShader :: struct {
	shader:       backend.Shader,
	entry_points: []backend.ShaderEntryPoint,
}

shader_create_session :: proc(
	global_session: ^sp.IGlobalSession,
	bindless_texture_count: u32,
	target: backend.ShaderTarget,
) -> (
	^sp.ISession,
	bool,
) {
	compiler_option_entries := []sp.CompilerOptionEntry {
		{name = .VulkanUseEntryPointName, value = {kind = .Int, intValue0 = 1}},
		{name = .GLSLForceScalarLayout, value = {kind = .Int, intValue0 = 1}},
	}
	assert(target == .SPIRV, "shader_create_session: only SPIR-V output is supported")
	target_desc := sp.TargetDesc {
		structureSize            = size_of(sp.TargetDesc),
		format                   = .SPIRV,
		flags                    = {.GENERATE_SPIRV_DIRECTLY},
		profile                  = global_session->findProfile("spirv"),
		compilerOptionEntries    = &compiler_option_entries[0],
		compilerOptionEntryCount = u32(len(compiler_option_entries)),
	}

	search_paths := [1]cstring{"shaders"}
	bindless_count_str := strings.clone_to_cstring(fmt.tprintf("%d", bindless_texture_count), context.temp_allocator)
	macros := [1]sp.PreprocessorMacroDesc{{name = "BINDLESS_TEXTURE_COUNT", value = bindless_count_str}}
	session_desc := sp.SessionDesc {
		structureSize           = size_of(sp.SessionDesc),
		targets                 = &target_desc,
		targetCount             = 1,
		defaultMatrixLayoutMode = .COLUMN_MAJOR,
		searchPaths             = &search_paths[0],
		searchPathCount         = 1,
		preprocessorMacros      = &macros[0],
		preprocessorMacroCount  = len(macros),
	}

	session: ^sp.ISession = nil
	if res := global_session->createSession(session_desc, &session); sp.FAILED(res) {
		log.errorf("Could not create Slang session")
		return nil, false
	}
	return session, true
}

shader_system_create :: proc(self: ^Engine, bindless_texture_count: u32) -> bool {
	ss := &self.shader_system
	if res := sp.createGlobalSession(sp.API_VERSION, &ss.global_session); sp.FAILED(res) {
		log.errorf("Could not create Slang global session")
		return false
	}

	// fail fast if a session can't be created with this config, even though
	// shader_load creates its own short-lived session per call
	session, ok := shader_create_session(
		ss.global_session,
		bindless_texture_count,
		backend.shader_target(&self.vk_ctx),
	)
	if !ok {
		return false
	}
	session->release()
	ss.bindless_texture_count = bindless_texture_count

	ss.loaded = make(map[string]LoadedShader)

	watcher.init(&ss.fw, "shaders")

	return true
}

shader_system_destroy :: proc(self: ^Engine) {
	ss := &self.shader_system
	for name, loaded in ss.loaded {
		backend.shader_destroy(&self.vk_ctx, loaded.shader)
		delete(loaded.entry_points)
		delete(name)
	}
	delete(ss.loaded)
	watcher.destroy(&ss.fw)
	ss.global_session->release()
}

// TODO: rewrite to learn the Slang API. COM boilerplate, three diagnostics blobs (diagnostics,
// diag, diag2).
// Compiles a Slang module to code for the given target. Pure Slang: no GPU objects, so an
// offline tool or a shader cache can produce the same bytes. The caller owns the result.
shader_compile :: proc(
	ss: ^ShaderSystem,
	module_name: string,
	entry_points: []backend.ShaderEntryPoint,
	target: backend.ShaderTarget,
	allocator := context.allocator,
) -> (
	code: []byte,
	ok: bool,
) {
	session, session_ok := shader_create_session(ss.global_session, ss.bindless_texture_count, target)
	if !session_ok {
		return nil, false
	}
	defer session->release()

	log.debugf("Compiling shader module: %s", module_name)

	diagnostics: ^sp.IBlob = nil
	module_name_cstr := strings.clone_to_cstring(module_name, context.temp_allocator)
	slang_module := session->loadModule(module_name_cstr, &diagnostics)
	log_slang_diagnostics(diagnostics, slang_module == nil)
	if slang_module == nil {
		log.errorf("Could not load Slang module: %s", module_name)
		return nil, false
	}

	ep_handles := make([]^sp.IEntryPoint, len(entry_points), context.temp_allocator)
	defer for ep in ep_handles {
		if ep != nil do ep->release()
	}
	for entry, i in entry_points {
		name_cstr := strings.clone_to_cstring(entry.name, context.temp_allocator)
		if res := slang_module->findEntryPointByName(name_cstr, &ep_handles[i]); sp.FAILED(res) {
			log.errorf("Could not find Slang entry point: %s", entry.name)
			return nil, false
		}
	}

	components := make([]^sp.IComponentType, 1 + len(entry_points), context.temp_allocator)
	components[0] = slang_module
	for ep, i in ep_handles {
		components[1 + i] = ep
	}

	linked: ^sp.IComponentType = nil
	// Diagnostics blobs can come back on success too (warnings); log_slang_diagnostics releases them.
	diag: ^sp.IBlob = nil
	link_res := session->createCompositeComponentType(&components[0], len(components), &linked, &diag)
	log_slang_diagnostics(diag, sp.FAILED(link_res))
	if sp.FAILED(link_res) {
		log.errorf("Could not link Slang module: %s", module_name)
		return nil, false
	}
	defer linked->release()

	target_code: ^sp.IBlob = nil
	diag2: ^sp.IBlob = nil
	code_res := linked->getTargetCode(0, &target_code, &diag2)
	log_slang_diagnostics(diag2, sp.FAILED(code_res))
	if sp.FAILED(code_res) {
		log.errorf("Could not get target code from Slang module: %s", module_name)
		return nil, false
	}
	defer target_code->release()

	return slice.clone(
			slice.bytes_from_ptr(target_code->getBufferPointer(), int(target_code->getBufferSize())),
			allocator,
		),
		true
}

// Compiles the module and creates its backend shader. Loading a name again recompiles it into
// the same handle, so pipelines keep referring to it; rebuild them to pick up the new code.
shader_load :: proc(
	self: ^Engine,
	module_name: string,
	entry_points: []backend.ShaderEntryPoint,
) -> (
	shader: backend.Shader,
	ok: bool,
) {
	ss := &self.shader_system
	code := shader_compile(ss, module_name, entry_points, backend.shader_target(&self.vk_ctx)) or_return
	defer delete(code)
	desc := backend.ShaderDesc {
		code         = code,
		entry_points = entry_points,
	}

	if loaded, exists := ss.loaded[module_name]; exists {
		backend.shader_replace(&self.vk_ctx, loaded.shader, desc)
		return loaded.shader, true
	}

	shader = backend.shader_create(&self.vk_ctx, desc)
	ss.loaded[strings.clone(module_name)] = {
		shader       = shader,
		entry_points = slice.clone(entry_points),
	}
	return shader, true
}

shader_poll_hotreload :: proc(self: ^Engine) {
	ss := &self.shader_system

	for ev in watcher.poll(&ss.fw) {
		if ev.event == .Removed {
			continue
		}

		filename := filepath.base(ev.path)

		// TODO: strings.trim_suffix instead of manual slicing.
		// strip ".slang" suffix to get module name
		module_name: string
		if len(filename) > 6 && filename[len(filename) - 6:] == ".slang" {
			module_name = filename[:len(filename) - 6]
		} else {
			continue
		}

		loaded, ok := ss.loaded[module_name]
		if !ok {
			continue
		}

		log.infof("Shader changed: %s — reloading pipelines", filename)

		// Recompile once with every entry point the module was loaded with, then rebuild each
		// pipeline that uses it.
		if _, load_ok := shader_load(self, module_name, loaded.entry_points); !load_ok {
			log.errorf("Shader reload '%s' failed, keeping old pipelines", module_name)
			continue
		}
		if pipelines_rebuild_for_shader(self, loaded.shader) do shadow_cache_invalidate(self)
	}
}

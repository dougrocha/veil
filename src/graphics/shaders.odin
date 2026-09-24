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

DEFAULT_VERTEX_ENTRY: cstring : VERTEX_ENTRY
DEFAULT_FRAGMENT_ENTRY: cstring : FRAGMENT_MAIN
DEFAULT_COMPUTE_ENTRY: cstring : COMPUTE_MAIN

ShaderHandle :: Handle(backend.ShaderModule)

INVALID_SHADER_HANDLE :: ShaderHandle{}

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
	modules:                Pool(backend.ShaderModule),
	name_to_handle:         map[string]ShaderHandle,
	fw:                     watcher.Watcher,
}

shader_create_session :: proc(
	global_session: ^sp.IGlobalSession,
	bindless_texture_count: u32,
) -> (
	^sp.ISession,
	bool,
) {
	when backend.VEIL_METAL {
		compiler_option_entries := []sp.CompilerOptionEntry{}
		target_desc := sp.TargetDesc {
			structureSize = size_of(sp.TargetDesc),
			format        = .METAL,
			profile       = global_session->findProfile("metal"),
		}
	} else when backend.VEIL_VULKAN {
		compiler_option_entries := []sp.CompilerOptionEntry {
			{name = .VulkanUseEntryPointName, value = {kind = .Int, intValue0 = 1}},
			{name = .GLSLForceScalarLayout, value = {kind = .Int, intValue0 = 1}},
		}
		target_desc := sp.TargetDesc {
			structureSize            = size_of(sp.TargetDesc),
			format                   = .SPIRV,
			flags                    = {.GENERATE_SPIRV_DIRECTLY},
			profile                  = global_session->findProfile("spirv"),
			compilerOptionEntries    = &compiler_option_entries[0],
			compilerOptionEntryCount = u32(len(compiler_option_entries)),
		}
	}

	search_paths := [1]cstring{"shaders"}
	bindless_count_str := strings.clone_to_cstring(fmt.tprintf("%d", bindless_texture_count), context.temp_allocator)
	metal_backend_value: cstring = backend.VEIL_METAL ? "1" : "0"
	macros := [2]sp.PreprocessorMacroDesc {
		{name = "BINDLESS_TEXTURE_COUNT", value = bindless_count_str},
		{name = "VEIL_METAL", value = metal_backend_value},
	}
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
	session, ok := shader_create_session(ss.global_session, bindless_texture_count)
	if !ok {
		return false
	}
	session->release()
	ss.bindless_texture_count = bindless_texture_count

	ss.modules = pool_init(256, backend.ShaderModule)
	ss.name_to_handle = make(map[string]ShaderHandle)

	watcher.init(&ss.fw, "shaders")

	return true
}

shader_system_destroy :: proc(self: ^Engine) {
	ss := &self.shader_system
	for &module, i in ss.modules.values {
		if pool_is_alive(&ss.modules, Index(i)) {
			backend.shader_module_destroy(&self.vk_ctx, module)
		}
	}
	watcher.destroy(&ss.fw)
	pool_destroy(&ss.modules)
	for name in ss.name_to_handle {
		delete(name)
	}
	delete(ss.name_to_handle)
	ss.global_session->release()
}

// Compiles a Slang module by name and caches the resulting VkShaderModule.
// entry_points lists the entry point names to link into the SPIR-V blob.
shader_load :: proc(self: ^Engine, module_name: string, entry_points: []string) -> (ShaderHandle, bool) {
	ss := &self.shader_system

	session, session_ok := shader_create_session(ss.global_session, ss.bindless_texture_count)
	if !session_ok {
		return INVALID_SHADER_HANDLE, false
	}
	defer session->release()

	log.debugf("Compiling shader module: %s", module_name)

	diagnostics: ^sp.IBlob = nil
	module_name_cstr := strings.clone_to_cstring(module_name, context.temp_allocator)
	slang_module := session->loadModule(module_name_cstr, &diagnostics)
	log_slang_diagnostics(diagnostics, slang_module == nil)
	if slang_module == nil {
		log.errorf("Could not load Slang module: %s", module_name)
		return INVALID_SHADER_HANDLE, false
	}

	ep_handles := make([]^sp.IEntryPoint, len(entry_points), context.temp_allocator)
	defer for ep in ep_handles {
		if ep != nil do ep->release()
	}
	for name, i in entry_points {
		name_cstr := strings.clone_to_cstring(name, context.temp_allocator)
		if res := slang_module->findEntryPointByName(name_cstr, &ep_handles[i]); sp.FAILED(res) {
			log.errorf("Could not find Slang entry point: %s", name)
			return INVALID_SHADER_HANDLE, false
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
		return INVALID_SHADER_HANDLE, false
	}
	defer linked->release()

	target_code: ^sp.IBlob = nil
	diag2: ^sp.IBlob = nil
	code_res := linked->getTargetCode(0, &target_code, &diag2)
	log_slang_diagnostics(diag2, sp.FAILED(code_res))
	if sp.FAILED(code_res) {
		log.errorf("Could not get SPIR-V from Slang module: %s", module_name)
		return INVALID_SHADER_HANDLE, false
	}
	defer target_code->release()

	code_bytes := slice.bytes_from_ptr(target_code->getBufferPointer(), int(target_code->getBufferSize()))
	when backend.VEIL_METAL {
		vk_module := backend.shader_module_create(&self.vk_ctx, string(code_bytes))
	} else when backend.VEIL_VULKAN {
		assert(uintptr(raw_data(code_bytes)) % align_of(u32) == 0, "Slang SPIR-V blob is not u32-aligned")
		spv_u32 := slice.reinterpret([]u32, code_bytes)
		vk_module := backend.shader_module_create(&self.vk_ctx, spv_u32)
	}

	// check if this module is being reloaded (update in place) or is new
	if existing, ok := ss.name_to_handle[module_name]; ok {
		module_ptr := pool_get(&ss.modules, existing)
		backend.shader_module_destroy(&self.vk_ctx, module_ptr^)
		module_ptr^ = vk_module
		return existing, true
	}

	handle := pool_alloc(&ss.modules, vk_module)
	ss.name_to_handle[strings.clone(module_name)] = handle
	return handle, true
}

shader_get :: proc(self: ^Engine, handle: ShaderHandle) -> backend.ShaderModule {
	return pool_get(&self.shader_system.modules, handle)^
}

shader_poll_hotreload :: proc(self: ^Engine) {
	ss := &self.shader_system

	for ev in watcher.poll(&ss.fw) {
		if ev.event == .Removed {
			continue
		}

		filename := filepath.base(ev.path)

		// strip ".slang" suffix to get module name
		module_name: string
		if len(filename) > 6 && filename[len(filename) - 6:] == ".slang" {
			module_name = filename[:len(filename) - 6]
		} else {
			continue
		}

		handle, ok := ss.name_to_handle[module_name]
		if !ok {
			continue
		}

		log.infof("Shader changed: %s — reloading pipelines", filename)

		for kind in PipelineKind {
			if self.pipeline_registry.shaders[kind] == handle {
				pipeline_reload(self, kind, module_name)
			}
		}
	}
}

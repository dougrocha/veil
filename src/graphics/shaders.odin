package graphics

import "core:log"
import "core:slice"
import "core:strings"
import linux "core:sys/linux"

import "backend"

import sp "shared:odin-slang/slang"
import vk "vendor:vulkan"

VERTEX_ENTRY :: "vertex_main"
FRAGMENT_MAIN :: "fragment_main"
COMPUTE_MAIN :: "compute_main"

DEFAULT_VERTEX_ENTRY: cstring : VERTEX_ENTRY
DEFAULT_FRAGMENT_ENTRY: cstring : FRAGMENT_MAIN

ShaderHandle :: Handle(vk.ShaderModule)

INVALID_SHADER_HANDLE :: ShaderHandle{}

ShaderSystem :: struct {
	global_session: ^sp.IGlobalSession,
	modules:        Pool(vk.ShaderModule),
	name_to_handle: map[string]ShaderHandle,
	inotify_fd:     linux.Fd,
	watch_fd:       linux.Wd,
}

create_shader_system :: proc(self: ^Engine) -> bool {
	ss := &self.shader_system
	if res := sp.createGlobalSession(sp.API_VERSION, &ss.global_session); sp.FAILED(res) {
		log.errorf("Could not create Slang global session")
		return false
	}
	ss.modules = pool_init(256, vk.ShaderModule)
	ss.name_to_handle = make(map[string]ShaderHandle)

	ifd, errno := linux.inotify_init1({.NONBLOCK})
	if errno != .NONE {
		log.warnf("inotify_init1 failed (%v), hot reload disabled", errno)
		ss.inotify_fd = linux.Fd(-1)
	} else {
		wfd, werr := linux.inotify_add_watch(ifd, "shaders", {.CLOSE_WRITE})
		if werr != .NONE {
			log.warnf("inotify_add_watch failed (%v), hot reload disabled", werr)
			linux.close(ifd)
			ss.inotify_fd = linux.Fd(-1)
		} else {
			ss.inotify_fd = ifd
			ss.watch_fd = wfd
		}
	}

	return true
}

destroy_shader_system :: proc(self: ^Engine) {
	ss := &self.shader_system
	for &module, i in ss.modules.values {
		if pool_is_alive(&ss.modules, u32(i)) {
			backend.shader_module_destroy(&self.vk_ctx, module)
		}
	}
	if ss.inotify_fd != linux.Fd(-1) {
		linux.close(ss.inotify_fd)
	}
	pool_destroy(&ss.modules)
	delete(ss.name_to_handle)
	ss.global_session->release()
}

// Compiles a Slang module by name and caches the resulting VkShaderModule.
// entry_points lists the entry point names to link into the SPIR-V blob.
load_shader :: proc(self: ^Engine, module_name: string, entry_points: []string) -> (ShaderHandle, bool) {
	ss := &self.shader_system

	compiler_option_entries := []sp.CompilerOptionEntry {
		{name = .VulkanUseEntryPointName, value = {kind = .Int, intValue0 = 1}},
		{name = .GLSLForceScalarLayout, value = {kind = .Int, intValue0 = 1}},
	}

	target_desc := sp.TargetDesc {
		structureSize            = size_of(sp.TargetDesc),
		format                   = .SPIRV,
		flags                    = {.GENERATE_SPIRV_DIRECTLY},
		profile                  = ss.global_session->findProfile("spirv"),
		compilerOptionEntries    = &compiler_option_entries[0],
		compilerOptionEntryCount = u32(len(compiler_option_entries)),
	}

	search_paths := [1]cstring{"shaders"}
	session_desc := sp.SessionDesc {
		structureSize            = size_of(sp.SessionDesc),
		targets                  = &target_desc,
		targetCount              = 1,
		defaultMatrixLayoutMode  = .COLUMN_MAJOR,
		searchPaths              = &search_paths[0],
		searchPathCount          = 1,
		compilerOptionEntries    = &compiler_option_entries[0],
		compilerOptionEntryCount = u32(len(compiler_option_entries)),
	}

	session: ^sp.ISession
	if res := ss.global_session->createSession(session_desc, &session); sp.FAILED(res) {
		log.errorf("Could not create Slang session")
		return INVALID_SHADER_HANDLE, false
	}
	defer session->release()

	log.debugf("Compiling shader module: %s", module_name)

	diagnostics: ^sp.IBlob
	module_name_cstr := strings.clone_to_cstring(module_name, context.temp_allocator)
	slang_module := session->loadModule(module_name_cstr, &diagnostics)
	if diagnostics != nil {
		log.errorf("Slang: %s", cstring(diagnostics->getBufferPointer()))
		diagnostics->release()
	}
	if slang_module == nil {
		log.errorf("Could not load Slang module: %s", module_name)
		return INVALID_SHADER_HANDLE, false
	}
	defer slang_module->release()

	ep_handles := make([]^sp.IEntryPoint, len(entry_points), context.temp_allocator)
	for name, i in entry_points {
		name_cstr := strings.clone_to_cstring(name, context.temp_allocator)
		if res := slang_module->findEntryPointByName(name_cstr, &ep_handles[i]); sp.FAILED(res) {
			log.errorf("Could not find Slang entry point: %s", name)
			return INVALID_SHADER_HANDLE, false
		}
		defer ep_handles[i]->release()
	}

	components := make([]^sp.IComponentType, 1 + len(entry_points), context.temp_allocator)
	components[0] = slang_module
	for ep, i in ep_handles {
		components[1 + i] = ep
	}

	linked: ^sp.IComponentType
	diag: ^sp.IBlob
	if res := session->createCompositeComponentType(&components[0], len(components), &linked, &diag); sp.FAILED(res) {
		if diag != nil {
			log.errorf("Slang link: %s", cstring(diag->getBufferPointer()))
			diag->release()
		}
		log.errorf("Could not link Slang module: %s", module_name)
		return INVALID_SHADER_HANDLE, false
	}
	defer linked->release()

	target_code: ^sp.IBlob
	diag2: ^sp.IBlob
	if res := linked->getTargetCode(0, &target_code, &diag2); sp.FAILED(res) {
		if diag2 != nil {
			log.errorf("Slang codegen: %s", cstring(diag2->getBufferPointer()))
			diag2->release()
		}
		log.errorf("Could not get SPIR-V from Slang module: %s", module_name)
		return INVALID_SHADER_HANDLE, false
	}
	defer target_code->release()

	spv := slice.bytes_from_ptr(target_code->getBufferPointer(), int(target_code->getBufferSize()))
	spv_u32 := slice.reinterpret([]u32, spv)
	vk_module := backend.shader_module_create(&self.vk_ctx, spv_u32)

	// check if this module is being reloaded (update in place) or is new
	if existing, ok := ss.name_to_handle[module_name]; ok {
		module_ptr := pool_get(&ss.modules, existing)
		vk.DestroyShaderModule(self.vk_ctx.device, module_ptr^, nil)
		module_ptr^ = vk_module
		return existing, true
	}

	handle := pool_alloc(&ss.modules, vk_module)
	ss.name_to_handle[strings.clone(module_name)] = handle
	return handle, true
}

get_shader :: proc(self: ^Engine, handle: ShaderHandle) -> vk.ShaderModule {
	return pool_get(&self.shader_system.modules, handle)^
}

check_shader_hotreload :: proc(self: ^Engine) {
	ss := &self.shader_system
	if ss.inotify_fd == linux.Fd(-1) {
		return
	}

	buf: [4096]u8
	n, _ := linux.read(ss.inotify_fd, buf[:])
	if n <= 0 {
		return
	}

	offset := 0
	for offset < n {
		event := (^linux.Inotify_Event)(raw_data(buf[offset:]))
		offset += size_of(linux.Inotify_Event) + int(event.len)

		if .CLOSE_WRITE not_in event.mask {
			continue
		}

		// extract filename from the variable-length name field
		name_ptr := (^u8)(uintptr(rawptr(event)) + size_of(linux.Inotify_Event))
		filename := string(cstring(name_ptr))

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

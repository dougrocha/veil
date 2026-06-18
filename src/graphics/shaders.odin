package graphics

import "core:log"
import "core:slice"
import "core:strings"

import sp "shared:odin-slang/slang"
import vk "vendor:vulkan"

VERTEX_ENTRY :: "vertex_main"
FRAGMENT_MAIN :: "fragment_main"
COMPUTE_MAIN :: "compute_main"

ShaderSystem :: struct {
	global_session: ^sp.IGlobalSession,
	modules:        map[string]vk.ShaderModule,
}

create_shader_system :: proc(self: ^Engine) -> bool {
	ss := &self.shader_system
	if res := sp.createGlobalSession(sp.API_VERSION, &ss.global_session); sp.FAILED(res) {
		log.errorf("Could not create Slang global session")
		return false
	}
	ss.modules = make(map[string]vk.ShaderModule)
	return true
}

destroy_shader_system :: proc(self: ^Engine) {
	ss := &self.shader_system
	for _, module in ss.modules {
		vk.DestroyShaderModule(self.device, module, nil)
	}
	delete(ss.modules)
	ss.global_session->release()
}

// Compiles a Slang module by name and caches the resulting VkShaderModule.
// entry_points lists the entry point names to link into the SPIR-V blob.
load_shader :: proc(self: ^Engine, module_name: string, entry_points: []string) -> bool {
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
		return false
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
		return false
	}
	defer slang_module->release()

	ep_handles := make([]^sp.IEntryPoint, len(entry_points), context.temp_allocator)
	for name, i in entry_points {
		name_cstr := strings.clone_to_cstring(name, context.temp_allocator)
		if res := slang_module->findEntryPointByName(name_cstr, &ep_handles[i]); sp.FAILED(res) {
			log.errorf("Could not find Slang entry point: %s", name)
			return false
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
		return false
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
		return false
	}
	defer target_code->release()

	spv := slice.bytes_from_ptr(target_code->getBufferPointer(), int(target_code->getBufferSize()))
	module_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spv),
		pCode    = raw_data(slice.reinterpret([]u32, spv)),
	}

	vk_module: vk.ShaderModule
	vk_check(vk.CreateShaderModule(self.device, &module_info, nil, &vk_module))
	ss.modules[module_name] = vk_module

	return true
}

get_shader :: proc(self: ^Engine, module_name: string) -> vk.ShaderModule {
	return self.shader_system.modules[module_name]
}

package graphics

import "core:log"
import "core:slice"

import sp "shared:odin-slang/slang"
import vk "vendor:vulkan"

slang_init :: proc(self: ^Engine) -> bool {
	if res := sp.createGlobalSession(sp.API_VERSION, &self.slang_session); sp.FAILED(res) {
		log.errorf("Could not create Slang global session")
		return false
	}
	return true
}

slang_cleanup :: proc(self: ^Engine) {
	self.slang_session->release()
}

// TODO: split this up so I can actually create new shaders
create_shaders_slang :: proc(self: ^Engine) -> bool {
	compiler_option_entries := []sp.CompilerOptionEntry {
		{name = .VulkanUseEntryPointName, value = {kind = .Int, intValue0 = 1}},
		{name = .GLSLForceScalarLayout, value = {kind = .Int, intValue0 = 1}},
	}

	target_desc := sp.TargetDesc {
		structureSize            = size_of(sp.TargetDesc),
		format                   = .SPIRV,
		flags                    = {.GENERATE_SPIRV_DIRECTLY},
		profile                  = self.slang_session->findProfile("spirv"),
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
	if res := self.slang_session->createSession(session_desc, &session); sp.FAILED(res) {
		log.errorf("Could not create Slang session")
		return false
	}
	defer session->release()

	log.debug("Compiling shaders")

	diagnostics: ^sp.IBlob
	module := session->loadModule("shader", &diagnostics)
	if diagnostics != nil {
		log.errorf("Slang: %s", cstring(diagnostics->getBufferPointer()))
		diagnostics->release()
	}
	if module == nil {
		log.errorf("Could not load Slang module")
		return false
	}
	defer module->release()

	vert_entry: ^sp.IEntryPoint
	if res := module->findEntryPointByName(VERTEX_ENTRY, &vert_entry); sp.FAILED(res) {
		log.errorf("Could not find Slang entry point: %s", VERTEX_ENTRY)
		return false
	}
	defer vert_entry->release()

	frag_entry: ^sp.IEntryPoint
	if res := module->findEntryPointByName(FRAGMENT_MAIN, &frag_entry); sp.FAILED(res) {
		log.errorf("Could not find Slang entry point: %s", FRAGMENT_MAIN)
		return false
	}
	defer frag_entry->release()

	components := [3]^sp.IComponentType{module, vert_entry, frag_entry}

	linked: ^sp.IComponentType
	diag: ^sp.IBlob
	if res := session->createCompositeComponentType(&components[0], len(components), &linked, &diag); sp.FAILED(res) {
		if diag != nil {
			log.errorf("Slang link: %s", cstring(diag->getBufferPointer()))
			diag->release()
		}
		log.errorf("Could not link Slang program")
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
		log.errorf("Could not get SPIR-V from Slang")
		return false
	}
	defer target_code->release()

	spv := slice.bytes_from_ptr(target_code->getBufferPointer(), int(target_code->getBufferSize()))
	module_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spv),
		pCode    = raw_data(slice.reinterpret([]u32, spv)),
	}

	vk_check(vk.CreateShaderModule(self.device, &module_info, nil, &self.shader_module))

	return true
}


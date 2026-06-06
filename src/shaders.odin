package main

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"

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

create_shaders_slang :: proc(self: ^Engine) -> bool {
	compiler_option_entries := [1]sp.CompilerOptionEntry{{name = .VulkanUseEntryPointName, value = {intValue0 = 1}}}
	target_desc := sp.TargetDesc {
		structureSize            = size_of(sp.TargetDesc),
		format                   = .SPIRV,
		flags                    = {.GENERATE_SPIRV_DIRECTLY},
		profile                  = self.slang_session->findProfile("sm_6_0"),
		compilerOptionEntries    = &compiler_option_entries[0],
		compilerOptionEntryCount = 1,
	}
	session_desc := sp.SessionDesc {
		structureSize = size_of(sp.SessionDesc),
		targets       = &target_desc,
		targetCount   = 1,
	}

	session: ^sp.ISession
	if res := self.slang_session->createSession(session_desc, &session); sp.FAILED(res) {
		log.errorf("Could not create Slang session")
		return false
	}
	defer session->release()

	shader_path :: "src/shaders/shader.slang"
	log.debug("Compiling shaders:", shader_path)

	src := read_file(shader_path, context.temp_allocator)
	src_cstr := strings.clone_to_cstring(src, context.temp_allocator)

	diagnostics: ^sp.IBlob
	module := session->loadModuleFromSourceString("shader", shader_path, src_cstr, &diagnostics)
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
	if res := module->findEntryPointByName("vertMain", &vert_entry); sp.FAILED(res) {
		log.errorf("Could not find Slang entry point: vertMain")
		return false
	}
	defer vert_entry->release()

	frag_entry: ^sp.IEntryPoint
	if res := module->findEntryPointByName("fragMain", &frag_entry); sp.FAILED(res) {
		log.errorf("Could not find Slang entry point: fragMain")
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

read_file :: proc(filepath: string, allocator := context.allocator) -> string {
	buf, err := os.read_entire_file(filepath, allocator)
	log.assertf(err == os.ERROR_NONE, "Failed to read file '%s': %v", filepath, err)
	return string(buf)
}


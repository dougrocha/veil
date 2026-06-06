package main

import "core:log"

import vk "vendor:vulkan"

vk_check :: proc(result: vk.Result, loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("Vulkan failure: %v", result, location = loc)
	}
}


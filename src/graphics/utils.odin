package graphics

import "core:log"
import "core:os"

read_file :: proc(filepath: string, allocator := context.allocator) -> string {
	buf, err := os.read_entire_file(filepath, allocator)
	log.assertf(err == os.ERROR_NONE, "Failed to read file '%s': %v", filepath, err)
	return string(buf)
}


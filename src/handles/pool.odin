package handles

import "base:runtime"
import "core:mem"

Index :: distinct u32
Generation :: distinct u32

Handle :: struct($T: typeid) {
	index:      Index,
	generation: Generation,
}

// Slot 0 is the nil slot: the zero handle resolves to it, read-only (see pool_get), pool_alloc never hands it
// out, and its generation stays 0 (never alive). Callers get a usable pool_capacity of max_capacity.
Pool :: struct($T: typeid) {
	values:      []T, // packed payloads, indexed directly by handle.index; values[0] is the nil slot
	generations: []Generation, // odd = alive, even = free; bumped on both alloc and free
	free_list:   [dynamic]Index,
	count:       u32, // high-water mark of slots in use, counting the nil slot
	nil_value:   T, // what the zero handle reads as; the default is the zero value
	allocator:   runtime.Allocator, // what the pool was created with; pool_destroy frees with it
}

pool_init :: proc(max_capacity: u32, $T: typeid, allocator := context.allocator) -> Pool(T) {
	pool: Pool(T)

	// only create the pool
	// cause honestly I dont care about free_list like this
	// and we dont know for sure how many free items will happen
	// +1 for the nil slot, so max_capacity stays the number of usable slots
	pool.values = make([]T, max_capacity + 1, allocator)
	pool.generations = make([]Generation, max_capacity + 1, allocator)
	pool.free_list = make([dynamic]Index, 0, max_capacity, allocator)
	pool.count = 1
	pool.allocator = allocator

	return pool
}

pool_destroy :: proc(pool: ^Pool($T)) {
	delete(pool.values, pool.allocator)
	delete(pool.generations, pool.allocator)
	delete(pool.free_list)
}

// What the zero handle reads as through pool_get. Defaults to the zero value. Call once, before any read;
// the nil slot is never written afterwards.
pool_set_nil :: proc(pool: ^Pool($T), value: T) {
	pool.nil_value = value
	pool.values[0] = value
}

// Usable slots, not counting the nil slot.
pool_capacity :: proc(pool: ^Pool($T)) -> u32 {
	return u32(len(pool.values)) - 1
}

// True when pool_alloc has no slot left.
pool_is_full :: proc(pool: ^Pool($T)) -> bool {
	return pool.count >= u32(len(pool.values)) && len(pool.free_list) == 0
}

pool_alloc :: proc(pool: ^Pool($T), value: T, loc := #caller_location) -> Handle(T) {
	assert(!pool_is_full(pool), "pool does not have a free slot", loc)

	insert_index: Index

	if len(pool.free_list) > 0 {
		insert_index = pop(&pool.free_list)
	} else {
		insert_index = Index(pool.count)
		pool.count += 1
	}

	assert(insert_index > 0 && insert_index < Index(len(pool.values)), "trying to insert past pool bounds", loc)

	pool.values[insert_index] = value
	pool.generations[insert_index] += 1 // now odd: alive

	return Handle(T){index = insert_index, generation = pool.generations[insert_index]}
}

pool_is_alive :: proc(pool: ^Pool($T), index: Index) -> bool {
	return pool.generations[index] % 2 == 1
}

// True when the handle points at a live slot of this pool. Unlike pool_get, never asserts:
// the zero handle, a freed handle and a reused slot all return false.
pool_is_valid :: proc(pool: ^Pool($T), handle: Handle(T)) -> bool {
	if handle.index >= Index(len(pool.values)) do return false
	return pool.generations[handle.index] == handle.generation && pool_is_alive(pool, handle.index)
}

// Slots currently allocated, not counting the nil slot.
pool_live_count :: proc(pool: ^Pool($T)) -> u32 {
	return pool.count - 1 - u32(len(pool.free_list))
}

// Helper method to validate a handle and return its index
//
// will crash and assert if invalid
_pool_check_handle :: proc(pool: ^Pool($T), handle: Handle(T), loc := #caller_location) -> Index {
	assert(handle != {}, "nil handle", loc)
	assert(handle.index < Index(len(pool.values)), "handle index out of bounds", loc)
	assert(pool.generations[handle.index] == handle.generation, "handle generation mismatch", loc)
	assert(pool_is_alive(pool, handle.index), "handle points to dead slot", loc)

	return handle.index
}

pool_free :: proc(pool: ^Pool($T), handle: Handle(T), loc := #caller_location) {
	index := _pool_check_handle(pool, handle, loc)
	pool.generations[index] += 1 // now even: dead
	append(&pool.free_list, index)
}

// The zero handle resolves to the nil slot. The nil slot is read-only by convention: set once by
// pool_set_nil (and at init), never reset here, so pool_get stays free of writes. ODIN_DEBUG builds
// assert slot 0 still equals nil_value, so a write through the nil pointer is caught at the next nil
// get. A stale or out-of-range handle still asserts.
pool_get :: proc(pool: ^Pool($T), handle: Handle(T), loc := #caller_location) -> ^T {
	if handle == {} {
		when ODIN_DEBUG {
			assert(
				mem.compare_ptrs(&pool.values[0], &pool.nil_value, size_of(T)) == 0,
				"nil slot was written through the zero handle",
				loc,
			)
		}
		return &pool.values[0]
	}
	return &pool.values[_pool_check_handle(pool, handle, loc)]
}

// Like pool_get, but the zero handle asserts too. For resources with no meaningful nil (GPU objects).
pool_get_live :: proc(pool: ^Pool($T), handle: Handle(T), loc := #caller_location) -> ^T {
	return &pool.values[_pool_check_handle(pool, handle, loc)]
}

package handles

Index :: distinct u32
Generation :: distinct u32

Handle :: struct($T: typeid) {
	index:      Index,
	generation: Generation,
}

Pool :: struct($T: typeid) {
	values:      []T, // packed payloads, indexed directly by handle.index
	generations: []Generation, // odd = alive, even = free; bumped on both alloc and free
	free_list:   [dynamic]Index,
	count:       u32,
}

pool_init :: proc(max_capacity: u32, $T: typeid, allocator := context.allocator) -> Pool(T) {
	pool: Pool(T)

	// only create the pool
	// cause honestly I dont care about free_list like this
	// and we dont know for sure how many free items will happen
	pool.values = make([]T, max_capacity, allocator)
	pool.generations = make([]Generation, max_capacity, allocator)
	pool.free_list = make([dynamic]Index, 0, max_capacity, allocator)
	pool.count = 0

	return pool
}

pool_destroy :: proc(pool: ^Pool($T), allocator := context.allocator) {
	delete(pool.values, allocator)
	delete(pool.generations, allocator)
	delete(pool.free_list)
}

pool_alloc :: proc(pool: ^Pool($T), value: T) -> Handle(T) {
	assert(pool.count < u32(len(pool.values)) || len(pool.free_list) > 0, "pool does not have a free slot")

	insert_index: Index

	if len(pool.free_list) > 0 {
		insert_index = pop(&pool.free_list)
	} else {
		insert_index = Index(pool.count)
		pool.count += 1
	}

	assert(insert_index < Index(len(pool.values)), "trying to insert past pool bounds")

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

// Slots currently allocated.
pool_live_count :: proc(pool: ^Pool($T)) -> u32 {
	return pool.count - u32(len(pool.free_list))
}

// Helper method to validate a handle and return its index
//
// will crash and assert if invalid
_pool_check_handle :: proc(pool: ^Pool($T), handle: Handle(T)) -> Index {
	assert(handle.index < Index(len(pool.values)), "handle index out of bounds")
	assert(pool.generations[handle.index] == handle.generation, "handle generation mismatch")
	assert(pool_is_alive(pool, handle.index), "handle points to dead slot")

	return handle.index
}

pool_free :: proc(pool: ^Pool($T), handle: Handle(T)) {
	index := _pool_check_handle(pool, handle)
	pool.generations[index] += 1 // now even: dead
	append(&pool.free_list, index)
}

pool_get :: proc(pool: ^Pool($T), handle: Handle(T)) -> ^T {
	index := _pool_check_handle(pool, handle)
	return &pool.values[index]
}

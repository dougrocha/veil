package graphics

// TODO: Add reference counting here
Slot :: struct($T: typeid) {
	value:      T, // the actual data
	generation: u32, // keeps track of reuse amount of this slot
	alive:      bool, // is this resource set
}

Handle :: struct($T: typeid) {
	index:      u32,
	generation: u32,
}

Pool :: struct($T: typeid) {
	slots:     []Slot(T),
	free_list: [dynamic]u32,
	count:     u32,
}

pool_init :: proc(max_capacity: u32, $T: typeid, allocator := context.allocator) -> Pool(T) {
	pool: Pool(T)

	// only create the pool
	// cause honestly I dont care about free_list like this
	// and we dont know for sure how many free items will happen
	pool.slots = make([]Slot(T), max_capacity, allocator)
	pool.free_list = make([dynamic]u32, 0, max_capacity, allocator)
	pool.count = 0

	return pool
}

pool_destroy :: proc(pool: ^Pool($T), allocator := context.allocator) {
	delete(pool.slots, allocator)
	delete(pool.free_list)
}

pool_alloc :: proc(pool: ^Pool($T), value: T) -> Handle(T) {
	assert(pool.count < u32(len(pool.slots)) || len(pool.free_list) > 0, "pool does not have a free slot")

	insert_index: u32

	if len(pool.free_list) > 0 {
		insert_index = pop(&pool.free_list)
	} else {
		insert_index = pool.count
		pool.count += 1
	}

	assert(insert_index < u32(len(pool.slots)), "trying to insert past pool bounds")

	slot := &pool.slots[insert_index]
	slot.value = value
	slot.generation += 1
	slot.alive = true

	return Handle(T){index = insert_index, generation = slot.generation}
}

// Helper method to get a slot from a handle
//
// will crash and assert if invalid
_pool_get_slot :: proc(pool: ^Pool($T), handle: Handle(T)) -> ^Slot(T) {
	assert(handle.index < u32(len(pool.slots)), "handle index out of bounds")

	slot := &pool.slots[handle.index]

	assert(slot.generation == handle.generation, "handle generation mismatch")
	assert(slot.alive, "handle points to dead slot")

	return slot
}

pool_free :: proc(pool: ^Pool($T), handle: Handle(T)) {
	slot := _pool_get_slot(pool, handle)
	slot.alive = false
	append(&pool.free_list, handle.index)
}

pool_get :: proc(pool: ^Pool($T), handle: Handle(T)) -> ^T {
	slot := _pool_get_slot(pool, handle)
	return &slot.value
}

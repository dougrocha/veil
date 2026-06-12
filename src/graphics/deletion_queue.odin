package graphics

DeletionQueue :: struct {
	deletors: [dynamic]proc(),
}

push_deletion :: proc(q: ^DeletionQueue, p: proc()) {
	append(&q.deletors, p)
}

flush_deletion_queue :: proc(q: ^DeletionQueue) {
	#reverse for d in q.deletors {
		d()
	}
	clear(&q.deletors)
}

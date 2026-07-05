package graphics

FileWatcher :: struct {
}

FileWatcherHandle :: u64

fw_create :: proc () -> FileWatcherHandle {
}

fw_destroy :: proc (handle: FileWatcherHandle) {
}

fw_poll :: proc(handle: FileWatcherHandle) {

}

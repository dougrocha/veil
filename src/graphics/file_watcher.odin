package graphics

import "core:log"
import "core:strings"
import linux "core:sys/linux"

FileWatcher :: struct {
	inotify_fd:    linux.Fd,
	watch_fd_list: [dynamic]linux.Wd,
}

fw_create :: proc() -> (FileWatcher, linux.Errno) {
	fw: FileWatcher
	ifd, errno := linux.inotify_init1({.NONBLOCK})

	if errno != .NONE {
		log.warnf("inotify_init1 failed (%v), file watch disabled", errno)
		fw.inotify_fd = linux.Fd(-1)
		return fw, errno
	}

	fw.inotify_fd = ifd
	fw.watch_fd_list = make([dynamic]linux.Wd)

	return fw, .NONE
}

fw_destroy :: proc(fw: ^FileWatcher) {
	for watch_fd in fw.watch_fd_list {
		linux.inotify_rm_watch(fw.inotify_fd, watch_fd)
	}
	delete(fw.watch_fd_list)

	linux.close(fw.inotify_fd)
}

fw_watch_path :: proc(fw: ^FileWatcher, path: string) {
	if fw.inotify_fd == -1 {
		log.warnf("cannot add file, file watcher is disabled")
		return
	}

	path := strings.clone_to_cstring(path, context.temp_allocator)

	wfd, werr := linux.inotify_add_watch(fw.inotify_fd, path, {.CLOSE_WRITE})
	if werr != .NONE {
		log.warnf("inotify_add_watch failed (%v), cannot watch file (%v)", werr, path)
		return
	}

	append(&fw.watch_fd_list, wfd)
}

fw_poll :: proc(fw: ^FileWatcher) {
	buf: [4096]u8

	n, _ := linux.read(fw.inotify_fd, buf[:])

}

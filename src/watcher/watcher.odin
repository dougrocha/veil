package watcher

import "base:runtime"
import "core:log"
import "core:path/filepath"
import "core:strings"
import linux "core:sys/linux" // only referenced in the .Linux when-branches

File_Event :: enum {
	Modified,
	Added,
	Removed,
}

Event_Data :: struct {
	path:  string,
	event: File_Event,
}

// Odin does not allow `when` blocks inside a struct body, so the platform
// handles live in a `when`-selected Platform_Data embedded with `using`.
when ODIN_OS == .Linux {
	Platform_Data :: struct {
		inotify_fd: i32,
		watch_fds:  map[i32]string, // watch descriptor -> dir path
	}
} else when ODIN_OS == .Darwin {
	Platform_Data :: struct {
		stream:   rawptr, // FSEventStreamRef
		run_loop: rawptr, // CFRunLoopRef
		// events pushed by the FSEvents callback, drained by poll()
		pending:  [dynamic]Event_Data,
	}
}

Watcher :: struct {
	using platform: Platform_Data,
	root_path:      string,
}

init :: proc(w: ^Watcher, root_path: string) -> bool {
	w.root_path = strings.clone(root_path)

	when ODIN_OS == .Linux {
		ifd, errno := linux.inotify_init1({.NONBLOCK})
		if errno != .NONE {
			log.warnf("inotify_init1 failed (%v), file watch disabled", errno)
			w.inotify_fd = -1
			return false
		}
		w.inotify_fd = i32(ifd)
		w.watch_fds = make(map[i32]string)

		path := strings.clone_to_cstring(root_path, context.temp_allocator)
		wfd, werr := linux.inotify_add_watch(
			linux.Fd(w.inotify_fd),
			path,
			{.CLOSE_WRITE, .CREATE, .DELETE, .MOVED_TO, .MOVED_FROM},
		)
		if werr != .NONE {
			log.warnf("inotify_add_watch failed (%v), cannot watch (%v)", werr, root_path)
			return false
		}
		w.watch_fds[i32(wfd)] = w.root_path

		return true
	} else when ODIN_OS == .Darwin {
		w.pending = make([dynamic]Event_Data)

		path := strings.clone_to_cstring(root_path, context.temp_allocator)
		cf_path := CFStringCreateWithCString(nil, path, kCFStringEncodingUTF8)
		if cf_path == nil {
			log.warnf("CFStringCreateWithCString failed, file watch disabled")
			return false
		}
		defer CFRelease(rawptr(cf_path))

		values := [1]rawptr{rawptr(cf_path)}
		cf_paths := CFArrayCreate(nil, &values[0], 1, &kCFTypeArrayCallBacks)
		defer CFRelease(rawptr(cf_paths))

		ctx := FSEventStreamContext {
			info = w,
		}
		w.stream = FSEventStreamCreate(
			nil,
			_fsevents_callback,
			&ctx,
			cf_paths,
			kFSEventStreamEventIdSinceNow,
			0.05, // latency in seconds; small debounce so editors' write bursts coalesce
			kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents,
		)
		if w.stream == nil {
			log.warnf("FSEventStreamCreate failed, file watch disabled")
			return false
		}

		// scheduled on the current (main) run loop: poll() pumps it, which
		// invokes _fsevents_callback synchronously on this same thread
		w.run_loop = CFRunLoopGetCurrent()
		FSEventStreamScheduleWithRunLoop(w.stream, w.run_loop, kCFRunLoopDefaultMode)

		if !FSEventStreamStart(w.stream) {
			log.warnf("FSEventStreamStart failed, file watch disabled")
			FSEventStreamInvalidate(w.stream)
			FSEventStreamRelease(w.stream)
			w.stream = nil
			return false
		}

		return true
	}
}

destroy :: proc(w: ^Watcher) {
	when ODIN_OS == .Linux {
		if w.inotify_fd != -1 {
			for wd in w.watch_fds {
				linux.inotify_rm_watch(linux.Fd(w.inotify_fd), linux.Wd(wd))
			}
			linux.close(linux.Fd(w.inotify_fd))
		}
		delete(w.watch_fds)
	} else when ODIN_OS == .Darwin {
		if w.stream != nil {
			FSEventStreamStop(w.stream)
			FSEventStreamInvalidate(w.stream)
			FSEventStreamRelease(w.stream)
			w.stream = nil
		}
		for ev in w.pending {
			delete(ev.path, runtime.default_allocator())
		}
		delete(w.pending)
	}

	delete(w.root_path)
}

// Returns the events since the last call. Event paths are allocated with
// `allocator` and stay valid until it is freed.
poll :: proc(w: ^Watcher, allocator := context.temp_allocator) -> []Event_Data {
	when ODIN_OS == .Linux {
		if w.inotify_fd == -1 {
			return nil
		}

		buf: [4096]u8
		n, _ := linux.read(linux.Fd(w.inotify_fd), buf[:])
		if n <= 0 {
			return nil
		}

		out := make([dynamic]Event_Data, allocator)

		offset := 0
		for offset < n {
			event := (^linux.Inotify_Event)(raw_data(buf[offset:]))
			offset += size_of(linux.Inotify_Event) + int(event.len)

			kind: File_Event
			switch {
			case .CLOSE_WRITE in event.mask:
				kind = .Modified
			case .CREATE in event.mask, .MOVED_TO in event.mask:
				kind = .Added
			case .DELETE in event.mask, .MOVED_FROM in event.mask:
				kind = .Removed
			case:
				continue
			}

			// extract filename from the variable-length name field
			name_ptr := (^u8)(uintptr(rawptr(event)) + size_of(linux.Inotify_Event))
			filename := string(cstring(name_ptr))
			if filename == "" {
				continue
			}

			dir := w.watch_fds[i32(event.wd)] or_else w.root_path
			path := filepath.join({dir, filename}, allocator) or_continue
			append(&out, Event_Data{path = path, event = kind})
		}

		return out[:]
	} else when ODIN_OS == .Darwin {
		if w.stream == nil {
			return nil
		}

		// pump the run loop (non-blocking) so FSEvents delivers callbacks now
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false)

		if len(w.pending) == 0 {
			return nil
		}

		out := make([]Event_Data, len(w.pending), allocator)
		for ev, i in w.pending {
			out[i] = {
				path  = strings.clone(ev.path, allocator),
				event = ev.event,
			}
			delete(ev.path, runtime.default_allocator())
		}
		clear(&w.pending)

		return out
	}
}

// ---------------------------------------------------------------------------
// Darwin FSEvents bindings (foreign imports are allowed inside `when` blocks,
// regular imports are not — which is why core:sys/linux is imported above).
// ---------------------------------------------------------------------------
when ODIN_OS == .Darwin {
	foreign import CoreFoundation "system:CoreFoundation.framework"
	foreign import CoreServices "system:CoreServices.framework"

	CFIndex :: int
	CFTimeInterval :: f64
	CFStringRef :: distinct rawptr
	CFArrayRef :: distinct rawptr

	kCFStringEncodingUTF8: u32 : 0x0800_0100

	CFArrayCallBacks :: struct {
		version:         CFIndex,
		retain:          rawptr,
		release:         rawptr,
		copyDescription: rawptr,
		equal:           rawptr,
	}

	FSEventStreamContext :: struct {
		version:         CFIndex,
		info:            rawptr,
		retain:          rawptr,
		release:         rawptr,
		copyDescription: rawptr,
	}

	FSEventStreamCallback :: proc "c" (
		stream: rawptr,
		info: rawptr,
		num_events: uint,
		event_paths: rawptr, // [^]cstring with the flags used here
		event_flags: [^]u32,
		event_ids: [^]u64,
	)

	kFSEventStreamEventIdSinceNow: u64 : 0xFFFF_FFFF_FFFF_FFFF

	kFSEventStreamCreateFlagNoDefer: u32 : 0x0000_0002
	kFSEventStreamCreateFlagFileEvents: u32 : 0x0000_0010

	kFSEventStreamEventFlagItemCreated: u32 : 0x0000_0100
	kFSEventStreamEventFlagItemRemoved: u32 : 0x0000_0200
	kFSEventStreamEventFlagItemRenamed: u32 : 0x0000_0800
	kFSEventStreamEventFlagItemModified: u32 : 0x0000_1000

	@(default_calling_convention = "c")
	foreign CoreFoundation {
		kCFRunLoopDefaultMode: CFStringRef
		kCFTypeArrayCallBacks: CFArrayCallBacks

		CFStringCreateWithCString :: proc(alloc: rawptr, str: cstring, encoding: u32) -> CFStringRef ---
		CFArrayCreate :: proc(alloc: rawptr, values: [^]rawptr, num_values: CFIndex, callbacks: ^CFArrayCallBacks) -> CFArrayRef ---
		CFRelease :: proc(cf: rawptr) ---
		CFRunLoopGetCurrent :: proc() -> rawptr ---
		CFRunLoopRunInMode :: proc(mode: CFStringRef, seconds: CFTimeInterval, return_after_source_handled: bool) -> i32 ---
	}

	@(default_calling_convention = "c")
	foreign CoreServices {
		FSEventStreamCreate :: proc(allocator: rawptr, callback: FSEventStreamCallback, ctx: ^FSEventStreamContext, paths_to_watch: CFArrayRef, since_when: u64, latency: CFTimeInterval, flags: u32) -> rawptr ---
		FSEventStreamScheduleWithRunLoop :: proc(stream: rawptr, run_loop: rawptr, mode: CFStringRef) ---
		FSEventStreamStart :: proc(stream: rawptr) -> bool ---
		FSEventStreamStop :: proc(stream: rawptr) ---
		FSEventStreamInvalidate :: proc(stream: rawptr) ---
		FSEventStreamRelease :: proc(stream: rawptr) ---
	}

	@(private)
	_fsevents_callback :: proc "c" (
		stream: rawptr,
		info: rawptr,
		num_events: uint,
		event_paths: rawptr,
		event_flags: [^]u32,
		event_ids: [^]u64,
	) {
		// OS-invoked C callback: no Odin context here, and pending outlives
		// the frame, so paths are cloned with the default heap allocator
		context = runtime.default_context()

		w := (^Watcher)(info)
		paths := ([^]cstring)(event_paths)

		for i in 0 ..< num_events {
			flags := event_flags[i]

			kind: File_Event
			switch {
			case flags & kFSEventStreamEventFlagItemRemoved != 0:
				kind = .Removed
			case flags & kFSEventStreamEventFlagItemCreated != 0:
				kind = .Added
			case flags & (kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed) != 0:
				kind = .Modified
			case:
				continue
			}

			append(&w.pending, Event_Data{path = strings.clone(string(paths[i])), event = kind})
		}
	}
}

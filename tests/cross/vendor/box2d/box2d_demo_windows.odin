#+build windows
package box2d_demo

import b2 "vendor:box2d"
import "core:c"

// Keep ucrtbase on the link line. The static box2d MSVC lib is CRT-light and
// references ucrt libc (malloc/free/...), but an unreferenced `system:` foreign
// import is pruned before symbol resolution. Using
// ucrt's aligned allocator as box2d's allocator callback keeps the import live,
// so ucrtbase.dll lands in the import table and box2d's libc symbols resolve.
foreign import _libc "system:ucrtbase.lib"

@(default_calling_convention = "c")
foreign _libc {
	_aligned_malloc :: proc(size, alignment: c.size_t) -> rawptr ---
	_aligned_free :: proc(ptr: rawptr) ---
}

box2d_alloc :: proc "c" (size: u32, alignment: i32) -> rawptr {
	return _aligned_malloc(c.size_t(size), c.size_t(alignment))
}
box2d_free :: proc "c" (mem: rawptr) {
	_aligned_free(mem)
}

set_box2d_allocator :: proc() {
	b2.SetAllocator(box2d_alloc, box2d_free)
}

#+build !windows
package box2d_demo

// On non-Windows targets box2d links its platform libc automatically and its
// default aligned allocator is fine, so there is nothing to keep live. This stub
// exists only so the cross-platform demo type-checks for linux/darwin too.
set_box2d_allocator :: proc() {}

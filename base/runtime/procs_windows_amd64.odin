#+private
#+no-instrumentation
package runtime

foreign import kernel32 "system:Kernel32.lib"

@(private)
foreign kernel32 {
	RaiseException :: proc "system" (dwExceptionCode, dwExceptionFlags, nNumberOfArguments: u32, lpArguments: ^uint) -> ! ---
}

windows_trap_array_bounds :: proc "contextless" () -> ! {
	EXCEPTION_ARRAY_BOUNDS_EXCEEDED :: 0xC000008C


	RaiseException(EXCEPTION_ARRAY_BOUNDS_EXCEEDED, 0, 0, nil)
}

windows_trap_type_assertion :: proc "contextless" () -> ! {
	windows_trap_array_bounds()
}

when ODIN_NO_CRT {
	// `__chkstk` is supplied by the freestanding startup support. On a native
	// Windows host it comes from the bundled `procs_windows_amd64.asm` (assembled
	// with nasm); on the Linux->Windows cross path nasm is unavailable, so the
	// `.asm` foreign import is skipped by the linker and `__chkstk` is instead
	// resolved from the bundled compiler-rt builtins archive.
	@(require)
	foreign import crt_lib "procs_windows_amd64.asm"

	// MSVC float-usage marker and TLS index. These are plain data symbols and do
	// not need assembly, so they are defined in pure Odin here (mirroring the
	// i386 path in `procs_windows_i386.odin`). Defining them in Odin rather than
	// in the `.asm` file means they are emitted by the compiler on every target,
	// including the cross path where the `.asm` is skipped. The `_fltused` value
	// `0x9875` matches what MSVC emits.
	@(private, export, link_name="_fltused")   _fltused:   i32 = 0x9875
	@(private, export, link_name="_tls_index") _tls_index: u32
}

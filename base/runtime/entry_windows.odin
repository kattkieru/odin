#+private
#+build windows
#+no-instrumentation
package runtime

import "base:intrinsics"

when ODIN_BUILD_MODE == .Dynamic {
	@(link_name="DllMain", linkage="strong", require)
	DllMain :: proc "system" (hinstDLL: rawptr, fdwReason: u32, lpReserved: rawptr) -> b32 {
		context = default_context()

		// Populate Windows DLL-specific globals
		dll_forward_reason = DLL_Forward_Reason(fdwReason)
		dll_instance       = hinstDLL

		switch dll_forward_reason {
		case .Process_Attach:
			when !ODIN_BEDROCK { #force_no_inline _startup_runtime() }
			intrinsics.__entry_point()
		case .Process_Detach:
			when !ODIN_BEDROCK { #force_no_inline _cleanup_runtime() }
		case .Thread_Attach:
			break
		case .Thread_Detach:
			break
		}
		return true
	}
} else when !ODIN_TEST && !ODIN_NO_ENTRY_POINT {
	when ODIN_ARCH == .i386 && !ODIN_NO_CRT {
		// Windows i386 with CRT: libcmt provides mainCRTStartup which calls _main
		// Note: "c" calling convention adds underscore prefix automatically on i386
		@(link_name="main", linkage="strong", require)
		main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
			args__ = argv[:argc]
			context = default_context()
			when !ODIN_BEDROCK { #force_no_inline _startup_runtime() }
			intrinsics.__entry_point()
			when !ODIN_BEDROCK { #force_no_inline _cleanup_runtime() }
			return 0
		}
	} else when ODIN_NO_CRT {
		// Freestanding (no-CRT) Windows entry. Without the MSVC CRT (libcmt) the
		// startup work the CRT would normally do has to be performed here:
		//   - acquire the command-line arguments (CRT would populate argv), and
		//   - terminate the process with the correct exit code (CRT would call
		//     ExitProcess with main's return value).
		// Only kernel32 symbols are used so the freestanding cross link needs no
		// import library beyond the already-bundled kernel32. CommandLineToArgvW
		// lives in shell32, so the command line is tokenized here instead (the
		// tokenizer matches CommandLineToArgvW's quoting/backslash rules), and
		// WideCharToMultiByte is avoided by converting UTF-16 -> UTF-8 in pure
		// Odin via runtime.encode_rune. Declared via a named kernel32 foreign
		// import to mirror the rest of base/runtime (os_specific_windows.odin,
		// heap_allocator_windows.odin).
		foreign import entry_kernel32 "system:Kernel32.lib"

		@(private="file")
		@(default_calling_convention="system")
		foreign entry_kernel32 {
			GetCommandLineW :: proc() -> [^]u16 ---
			ExitProcess     :: proc(uExitCode: u32) -> ! ---
		}

		@(link_name="mainCRTStartup", linkage="strong", require)
		mainCRTStartup :: proc "system" () -> i32 {
			context = default_context()

			// Acquire command-line arguments via Win32 and feed runtime.args__,
			// which core:os exposes as os.args. Mirrors what the CRT supplies via
			// argv on the native path. UTF-16 argv is converted to UTF-8 cstrings
			// (os.args treats each entry as a UTF-8 string).
			//
			// This must run BEFORE _startup_runtime(): core:os snapshots args__
			// into os.args during package initialization (os.args is a file-scope
			// `args := get_args()`), so args__ has to be populated first. The CRT
			// path sets args__ before startup for the same reason. Allocation only
			// needs the context (set above), not the runtime startup, and
			// _acquire_windows_args uses an explicit allocator/heap_alloc.
			when !ODIN_BEDROCK {
				_acquire_windows_args()
			}

			when !ODIN_BEDROCK { #force_no_inline _startup_runtime() }
			intrinsics.__entry_point()
			when !ODIN_BEDROCK { #force_no_inline _cleanup_runtime() }

			// No CRT means nothing consumes this return value, so terminate the
			// process explicitly. A clean (normal) return is exit code 0; an
			// early os.exit(code) already called ExitProcess with its own code.
			ExitProcess(0)
		}

		@(private="file")
		_acquire_windows_args :: proc "odin" () {
			cmd_line := GetCommandLineW()
			if cmd_line == nil {
				return
			}

			// Length of the UTF-16 command line (excluding the NUL terminator).
			cmd_len := 0
			for cmd_line[cmd_len] != 0 {
				cmd_len += 1
			}
			cmd := cmd_line[:cmd_len]

			// First pass: count args and total UTF-8 byte size (including a NUL
			// terminator per arg). Second pass: emit. Both share the tokenizer so
			// the sizes agree.
			argc, total := _tokenize_windows_cmdline(cmd, nil, 0)
			if argc <= 0 {
				return
			}

			// One backing block holds all argument bytes contiguously; cstrings
			// point into it. The whole block is leaked for the process lifetime
			// (mirrors how the CRT's argv lives for the program's duration).
			buf := ([^]u8)(heap_alloc(total))
			if buf == nil {
				return
			}

			args := make([]cstring, argc, default_allocator())
			if args == nil {
				heap_free(buf)
				return
			}

			argc2, _ := _tokenize_windows_cmdline(cmd, &Tokenize_Out{buf, raw_data(args)}, total)
			_ = argc2
			args__ = args
		}

		@(private="file")
		Tokenize_Out :: struct {
			buf:  [^]u8,      // packed, NUL-separated UTF-8 argument strings
			args: [^]cstring, // one cstring per arg, pointing into buf
		}

		// Splits a Windows UTF-16 command line into UTF-8 arguments following the
		// same rules as CommandLineToArgvW / the MSVC CRT argv parser:
		//   - whitespace (space/tab) separates arguments,
		//   - double quotes group whitespace into a single argument,
		//   - 2n backslashes followed by '"' -> n backslashes + quote toggle,
		//   - 2n+1 backslashes followed by '"' -> n backslashes + literal '"'.
		// argv[0] (program name) uses slightly simpler rules in the CRT, but the
		// general rules produce the same result for the common cases.
		// UTF-16 (with surrogate pairs) is decoded to runes and re-encoded to
		// UTF-8 via encode_rune, avoiding any dependency on WideCharToMultiByte.
		// When `out` is nil only counts are computed (argc and total UTF-8 byte
		// size including a NUL per arg). Otherwise args are written into out.buf
		// and out.args. Returns (argc, total_bytes).
		@(private="file")
		_tokenize_windows_cmdline :: proc "contextless" (cmd: []u16, out: ^Tokenize_Out, cap: int) -> (argc: int, total: int) {
			n := len(cmd)
			i := 0

			// Emit one UTF-8-encoded rune into the backing buffer (or just count).
			emit :: proc "contextless" (out: ^Tokenize_Out, cap: int, total: ^int, r: rune) {
				bytes, w := encode_rune(r)
				if out != nil {
					for k in 0..<w {
						if total^ + k < cap {
							out.buf[total^ + k] = bytes[k]
						}
					}
				}
				total^ += w
			}

			for {
				// Skip whitespace between arguments.
				for i < n && (cmd[i] == ' ' || cmd[i] == '\t') {
					i += 1
				}
				if i >= n {
					break
				}

				// Begin a new argument; record where its bytes start.
				if out != nil {
					out.args[argc] = cstring(&out.buf[total])
				}
				argc += 1

				in_quotes := false
				for i < n {
					c := cmd[i]
					if c == '\\' {
						bs := 0
						for i < n && cmd[i] == '\\' {
							bs += 1
							i += 1
						}
						if i < n && cmd[i] == '"' {
							for _ in 0..<(bs / 2) {
								emit(out, cap, &total, '\\')
							}
							if bs & 1 == 1 {
								emit(out, cap, &total, '"')
								i += 1
							}
							// even count: the quote is a delimiter, next iteration
						} else {
							for _ in 0..<bs {
								emit(out, cap, &total, '\\')
							}
						}
						continue
					}
					if c == '"' {
						in_quotes = !in_quotes
						i += 1
						continue
					}
					if !in_quotes && (c == ' ' || c == '\t') {
						break
					}

					// Decode one UTF-16 code unit (handling surrogate pairs).
					r := rune(c)
					if c >= 0xD800 && c <= 0xDBFF && i+1 < n {
						lo := cmd[i+1]
						if lo >= 0xDC00 && lo <= 0xDFFF {
							r = rune(0x10000 + (u32(c-0xD800) << 10) + u32(lo-0xDC00))
							i += 1
						}
					}
					emit(out, cap, &total, r)
					i += 1
				}

				// NUL terminator for this argument.
				if out != nil && total < cap {
					out.buf[total] = 0
				}
				total += 1
			}

			return argc, total
		}
	} else {
		@(link_name="main", linkage="strong", require)
		main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
			args__ = argv[:argc]
			context = default_context()
			when !ODIN_BEDROCK { #force_no_inline _startup_runtime() }
			intrinsics.__entry_point()
			when !ODIN_BEDROCK { #force_no_inline _cleanup_runtime() }
			return 0
		}
	}
}
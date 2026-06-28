# Generated `windows_amd64` link libraries (import libs + compiler-rt builtins)

This directory ships the libraries the bundled cross linker
(`bin/windows-cross/lld-link`) links a `windows_amd64` executable against when
the Odin compiler runs on **Linux** with no Microsoft Visual C++ SDK installed:

- the MSVC-style **import libraries** (`.lib`) for the system DLLs, and
- the **compiler-rt builtins** archive
  (`libclang_rt.builtins-x86_64.a`) that supplies the LLVM runtime builtins
  (integer math helpers, `__chkstk`, soft-float, ...) that no Windows system DLL
  provides.

Both are **pre-generated at Odin-distribution packaging time** by the Linux
packaging host (which has the pinned LLVM/clang toolchain) and shipped inside the
distribution, so the link step on the user's machine needs no `dlltool`, no
`clang`, and no MSVC SDK.

## Contents

| File                          | Description                                                                                     |
| ----------------------------- | ---------------------------------------------------------------------------------------------- |
| `kernel32.lib`                | Import lib for `kernel32.dll` (generated; base set).                                            |
| `ucrtbase.lib`                | Import lib for `ucrtbase.dll` / UCRT subset (generated; base set).                              |
| `bcrypt.lib`                  | Import lib for `bcrypt.dll` — `BCryptGenRandom` (generated; default-runtime random).            |
| `ntdll.lib`                   | Import lib for `ntdll.dll` — `RtlGetVersion` (generated; OS-version queries).                   |
| `user32.lib`                  | Import lib for `user32.dll` — windowing (generated; vendor:raylib/glfw).                         |
| `gdi32.lib`                   | Import lib for `gdi32.dll` — GDI device contexts (generated; vendor:raylib/glfw).                |
| `shell32.lib`                 | Import lib for `shell32.dll` — shell integration (generated; vendor:raylib/glfw).               |
| `winmm.lib`                   | Import lib for `winmm.dll` — multimedia timing (generated; vendor:raylib).                       |
| `opengl32.lib`                | Import lib for `opengl32.dll` — GL/WGL (generated; bundled for future GL-direct demos).          |
| `libclang_rt.builtins-x86_64.a` | compiler-rt builtins for `x86_64-pc-windows-msvc` (generated).                                |
| `generate-import-libs.sh`     | Packaging step: regenerates the import `.lib` files from `../def/`.                             |
| `generate-compiler-rt.sh`     | Packaging step: builds `libclang_rt.builtins-x86_64.a` from the vendored `../compiler-rt/builtins` sources. |
| `README.md`                   | This file.                                                                                      |

The `.lib`/`.a` files are **build outputs**, not hand-authored: do not edit them.
Regenerate the import libs by refreshing `../def/` and re-running
`generate-import-libs.sh`; regenerate the builtins with `generate-compiler-rt.sh`.

## compiler-rt builtins (`libclang_rt.builtins-x86_64.a`)

LLVM-emitted code references runtime "builtins" that are **not** part of any
Windows system DLL: 64/128-bit integer math helpers (`__udivti3`, `__multi3`,
`__divti3`, ...), soft-float helpers, and the stack-probe routine `__chkstk`
(emitted for large stack frames). On native MSVC these come from the static CRT
(`libcmt` / `chkstk.obj`); on the Linux→`windows_amd64` cross path there is no
MSVC CRT, so they are supplied by this bundled archive.

`generate-compiler-rt.sh` compiles the **vendored** LLVM **`compiler-rt`**
builtins sources (`../compiler-rt/builtins`, pinned to the LLVM version) for
`--target=x86_64-pc-windows-msvc` with the pinned `clang`, then archives them
with `llvm-ar`. Building from source (instead of vendoring a prebuilt
`.lib`) is deliberate: the official LLVM *Linux* release ships only a *Linux*
builtins archive, and the LLVM *Windows* release archive is produced by MSVC's
`cl.exe`. Compiling the upstream sources with the pinned clang for the MSVC ABI
target yields the canonical, ABI-correct `windows_amd64` builtins reproducibly on
the Linux packaging host.

Two windows-specific details the script handles:

- **80-bit `long double` sources are excluded.** On the MSVC ABI `long double`
  is 64-bit, so the `xf_float` (80-bit) builtins do not apply. The script selects
  sources by attempting to compile each candidate for the target and keeping the
  ones that build, so the platform-inapplicable sources drop out automatically
  (matching compiler-rt's own per-platform selection).
- **`__chkstk` alias.** compiler-rt's `x86_64/chkstk.S` defines only
  `___chkstk_ms` (the cygwin/mingw name); LLVM emits `__chkstk` on the MSVC ABI.
  The two share the same x86-64 contract (probe-only, `%rsp` not adjusted, `%rax`
  preserved), so the script adds a tiny `__chkstk` that jumps to `___chkstk_ms`.
- **MSVC CRT-support stubs** (`msvc_crt_support.c`). MSVC compiles its C/C++
  *static* `.lib`s — e.g. the vendored `vendor:cgltf` and `vendor:box2d` — with
  `/GS` (buffer-security cookie), `/RTCs` (range checks) and ISA-dispatch helpers,
  so those `.obj`s reference a handful of symbols that on native MSVC come from
  `libcmt` / `libvcruntime`: `__security_cookie`, `__security_check_cookie`,
  `__GSHandlerCheck`, `__report_rangecheckfailure`, `__isa_available`. They are
  **not** `ucrtbase.dll` exports (they are static-CRT internals), so they cannot
  come from the import libs, and the cross path links `/nodefaultlib` (no
  `libcmt`). The script adds minimal, ABI-faithful definitions: `__security_cookie`
  / `__isa_available` are writable globals with the canonical MSVC defaults
  (`0x00002B992DDFA232` / `0`); `__security_check_cookie` returns if the frame
  cookie matches else `__fastfail`s; `__report_rangecheckfailure` `__fastfail`s;
  `__GSHandlerCheck` returns `EXCEPTION_CONTINUE_SEARCH`. This lets every
  MSVC-compiled static vendor lib link with the bundled toolchain alone (the
  static-`.lib` analog of the `__chkstk` alias above; an early stack probe).
  `_fltused` is **not** here — Odin's runtime exports it
  itself (`base/runtime/procs_windows_amd64.odin`).

This archive is linked positionally on the cross path (see
`src/linker.cpp`, the `cross-lld-link` invocation), so `lld-link` pulls in only
the members needed to resolve otherwise-undefined builtin symbols.

### License / attribution

compiler-rt is part of the LLVM Project and is distributed under the **Apache
License v2.0 with LLVM Exceptions** (the same license as the bundled `lld-link`).
The full text is in `bin/windows-cross/LICENSE.TXT`. The source is fetched from
the official upstream release at
<https://github.com/llvm/llvm-project/releases> (`compiler-rt-<ver>.src.tar.xz`),
matching Odin's pinned LLVM major.

## Minimal UCRT surface (`ucrtbase.lib`)

`ucrtbase.lib` is the import lib for the **redistributable** Universal CRT DLL
(`ucrtbase.dll`). It is bundled, but on the Linux→`windows_amd64` cross path it is
linked **only when a package actually declares it** via `foreign import` — there
is no unconditional `/defaultlib:` and nothing force-names `ucrtbase.lib`. Each
system lib reaches the `lld-link` command line through the
`gen->foreign_libraries` loop in `src/linker.cpp`, so an import lib is pulled in
only on demand. This keeps the cross dependency surface minimal.

**Default UCRT requirement: none.** A default program (`core:fmt` + basic `core:os`)
pulls in **zero** UCRT symbols. Odin's Windows runtime is freestanding:

| Need                       | Source DLL / lib | Symbols                                                                 |
| -------------------------- | ---------------- | ---------------------------------------------------------------------- |
| heap allocation            | `kernel32`       | `GetProcessHeap`, `HeapAlloc`, `HeapReAlloc`, `HeapFree`               |
| stdio / files (`core:os`)  | `kernel32`       | `GetStdHandle`, `WriteFile`, `ReadFile`, `GetFileType`, `SetFilePointer`, `GetFileInformationByHandle*`, `GetFileSizeEx`, `FlushFileBuffers`, `CloseHandle`, `PeekNamedPipe`, `GetConsoleMode`, `GetFinalPathNameByHandleW`, `SetHandleInformation`, `WideCharToMultiByte` |
| startup / exit / args      | `kernel32`       | `GetCommandLineW`, `ExitProcess`, `RaiseException`, `GetLastError`     |
| locks / sysinfo            | `kernel32`       | `AcquireSRWLock*`, `ReleaseSRWLock*`, `GetSystemInfo`, `RtlFillMemory`, `RtlMoveMemory` |
| random (`core:runtime`)    | `bcrypt`         | `BCryptGenRandom`                                                       |
| LLVM builtins (math/chkstk)| compiler-rt `.a` | `__chkstk`, `__udivti3`, `__multi3`, ... (self-contained, no UCRT)     |

(Enumerated empirically by linking a `core:fmt`+`core:os` hello-world
`-target:windows_amd64 -no-crt` and listing the undefined externals; the produced
PE imports only `KERNEL32.dll` + `bcrypt.dll`.) So a hello-world links with at
most **kernel32 + bcrypt** — `ucrtbase` is not referenced at all on the default path.

**When ucrtbase *is* needed.** Code that explicitly `foreign import`s the C
runtime reaches UCRT. The broad case is `core:c/libc`; it is **not supported on the cross path**.
Note a naming caveat for future expansion: `core:c/libc` imports
`system:libucrt.lib` (the MSVC *static*-UCRT import-lib name), whereas the bundled
cross import lib is `ucrtbase.lib` (the *redistributable* DLL). Wiring `core:c/libc`
through the cross path will therefore need either a `libucrt.lib` import lib (a
`.def` for the static UCRT) or an alias/redirect from `libucrt` to `ucrtbase` —
this is future work.

## How they are generated

`generate-import-libs.sh` runs, for each DLL in its list (the base set plus the
vendor-demo set user32/gdi32/shell32/winmm/opengl32):

```sh
llvm-dlltool -m i386:x86-64 -d ../def/x86_64/<name>.def -l ./<name>.lib
```

- `-m i386:x86-64` selects the **amd64** (x86-64) COFF import library. The output
  is `windows_amd64` content regardless of the host architecture, so the arm64
  Linux packaging job produces byte-identical libs to the amd64 job.
- The inputs are the resolved
  `../def/x86_64/{kernel32,ucrtbase,bcrypt,ntdll,user32,gdi32,shell32,winmm,opengl32}.def`
  files in `../def/` (see `../def/README.md`).

## Version pinning / reproducibility

Both the import libs and the compiler-rt builtins MUST be generated with the
**same LLVM major** the Odin compiler and the bundled `lld-link` are pinned to
(currently **20** -- see `ci/build_linux_static.sh`,
`.github/workflows/nightly.yml`, and `../README.md`). The packaging job runs the
generation inside the LLVM-20 Alpine container, so the import libs, the
compiler-rt builtins, and `lld-link` stay in lock-step. Whenever the bundled
LLVM major is bumped, re-run **both** generators with the matching tools so all
of them are regenerated together:

    DLLTOOL=llvm-dlltool-20 ./generate-import-libs.sh
    CLANG=clang-20 LLVM_AR=llvm-ar-20 LLVM_VERSION=20.1.8 ./generate-compiler-rt.sh

`generate-compiler-rt.sh` defaults `LLVM_VERSION` to the exact pinned
compiler-rt release; update it together with the LLVM major bump.

## Packaging wiring

The Linux nightly job (`.github/workflows/nightly.yml`) runs both
`generate-import-libs.sh` and `generate-compiler-rt.sh` inside the LLVM-20 build
container right after building `odin`, so the freshly generated `.lib`/`.a` files
are copied into the release tarball together with the rest of `bin/`.

`ci/remove_windows_binaries.sh` strips Windows-*host* binaries (`*.exe`,
`*.dll`, `*.lib`, ...) from non-Windows artifacts, but it explicitly excludes
this `bin/windows-cross/lib/` directory (`! -path '*/bin/windows-cross/lib/*'`)
so these cross-compilation libraries survive into the Linux/macOS distribution.

## Tracking under `bin/`

`bin/` is `.gitignore`d. Like the sibling bundled tooling/data, anything you want
committed here must be force-added:

    git add -f bin/windows-cross/lib

In practice the `.lib`/`.a` files are produced by the packaging job and shipped
in the release artifact; they do not need to be committed to the repository (they
are regenerable build outputs). Commit the generator scripts and this README; the
generated libraries are an artifact of the build.

## Provisioning note

> The actual `kernel32.lib` / `ucrtbase.lib` /
> `libclang_rt.builtins-x86_64.a` are emitted at packaging time by the generator
> scripts. They are intentionally not committed here (they are reproducible build
> outputs). If you need them locally for a manual cross build, install the
> LLVM-20 tools and run `./generate-import-libs.sh` and
> `./generate-compiler-rt.sh` (the latter downloads the upstream compiler-rt
> source; point it at a local copy with `COMPILER_RT_SRC=` for offline use).

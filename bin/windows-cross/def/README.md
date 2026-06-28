# Vendored MinGW-w64 `.def` files (Windows system-DLL export lists)

This directory ships module-definition (`.def`) files listing the exported
symbols of the Windows system DLLs that an Odin compiler running on **Linux**
needs in order to produce `windows_amd64` import libraries **without** the
Microsoft Visual C++ SDK installed.

The next pipeline step feeds these `.def` files to `llvm-dlltool`
to synthesize the `.lib` import libraries that `lld-link` links against. Nothing
here is Microsoft SDK content: these are MinGW-w64's independently-maintained,
permissively-licensed export lists for the same public DLLs.

## Base set

| DLL             | Why it is needed                                                |
| --------------- | -------------------------------------------------------------- |
| `kernel32.dll`  | Core Win32 kernel API (process/thread/file/memory/etc.).       |
| `ucrtbase.dll`  | Universal CRT runtime (the UCRT subset Odin links against).    |
| `bcrypt.dll`    | `BCryptGenRandom` — `base/runtime`'s default random source.    |
| `ntdll.dll`     | `RtlGetVersion` — `core:sys/info` / `core:os` version queries. |

`kernel32`/`ucrtbase` cover the Win32 + UCRT surface; `bcrypt`/`ntdll` are
additionally required so a default `core:sys/windows` (`core:fmt` + `core:os`)
program cross-links with no `-windows-sysroot` / `-extra-linker-flags`
workaround.

## Vendor-demo set

| DLL             | Why it is needed                                                |
| --------------- | -------------------------------------------------------------- |
| `user32.dll`    | Windowing (`CreateWindowExW`/`GetMessageW`) — raylib + glfw.    |
| `gdi32.dll`     | GDI device contexts (`CreateCompatibleDC`) — raylib + glfw.     |
| `shell32.dll`   | Shell integration (`ShellExecuteW`) — raylib + glfw.           |
| `winmm.dll`     | Multimedia timing (`timeGetTime`) — raylib.                     |
| `opengl32.dll`  | GL/WGL entry points (`wglCreateContext`) — bundled for completeness / future GL-direct demos (no current demo links it; `vendor:OpenGL` loads GL via a proc-address callback). |

These are pulled by the Windows `system:` link lines of `vendor:raylib`
(`Winmm/Gdi32/User32/Shell32`) and `vendor:glfw` (`user32/gdi32/shell32`). The
bindings use mixed case, but the cross resolver lowercases the lib name, so the
files are shipped lowercase.

The layout below makes adding more DLLs (e.g. `advapi32`, `ws2_32`) a
copy-and-regenerate operation — drop the MinGW-w64 source into `src/` and add the
base name to the lists in `regenerate.sh` and `../lib/generate-import-libs.sh`.

## Layout

```
def/
  COPYING.MinGW-w64-runtime.txt   MinGW-w64 runtime license / attribution (see below)
  README.md                       this file
  regenerate.sh                   regenerates x86_64/*.def from src/*.def(.in)
  src/                            verbatim MinGW-w64 source templates (provenance)
    kernel32.def.in
    ucrtbase.def.in
    ucrtbase-common.def.in
    ntdll.def.in
    user32.def.in                 .def.in template (lib-common upstream)
    bcrypt.def                    plain .def (no arch macros; lib-common upstream)
    gdi32.def                     plain .def (no arch macros; lib-common upstream)
    shell32.def                   plain .def (no arch macros; lib-common upstream)
    winmm.def                     plain .def (no arch macros; lib-common upstream)
    opengl32.def                  plain .def (no arch macros; lib-common upstream)
    def-include/
      func.def.in                 DEF_<ARCH> -> F32/F64/F_X64/... macro expansion
      crt-aliases.def.in          msvcrt-compat symbol aliases (used by ucrtbase)
  x86_64/                         resolved, ready-to-consume .def files
    kernel32.def
    ucrtbase.def
    bcrypt.def
    ntdll.def
    user32.def
    gdi32.def
    shell32.def
    winmm.def
    opengl32.def
```

Most upstream lists are C-preprocessor templates (`*.def.in`); a few (e.g.
`bcrypt`) ship as a flat `*.def` with no arch macros. `regenerate.sh` runs both
through the same cpp pipeline (preferring `src/<name>.def.in`, falling back to
`src/<name>.def`) — a flat `.def` has no `#`-directives, so it passes through
unchanged.

- **`x86_64/*.def`** are the files the packaging / import-lib step consumes. They
  are the C-preprocessed result of the matching `src/*.def.in` for the
  `x86_64` (MinGW `DEF_X64`) target, with blank lines stripped. They are plain
  `.def` files: a `LIBRARY "<dll>"` line, an `EXPORTS` line, one symbol per line,
  plus `alias == real` re-export entries (valid `llvm-dlltool` syntax) and
  `;`-comments.
- **`src/*.def.in`** are committed verbatim from MinGW-w64 so the resolved files
  are reproducible and auditable. Do not hand-edit `x86_64/*.def`; edit/refresh
  `src/` and run `regenerate.sh`.

## How the `.def.in` -> `.def` step works

MinGW-w64 distributes export lists as C-preprocessor templates. A symbol wrapped
in `F_X64(x)` / `F64(x)` / `F_X86_ANY(x)` etc. is emitted only for the
architectures those macros select; `src/def-include/func.def.in` turns the
single `DEF_<ARCH>` define into the right set of `F_*` expansions. `ucrtbase`
additionally pulls in `ucrtbase-common.def.in` and `crt-aliases.def.in`.

`regenerate.sh` reproduces MinGW-w64's own build step:

```sh
cc -E -xc -nostdinc -P -DDEF_X64 -Isrc/def-include src/kernel32.def.in \
   | grep -v '^[[:space:]]*$' > x86_64/kernel32.def
```

(Only `#`-directives are processed; the `;`-comments and `==` aliases pass
through unchanged. MinGW-w64's comment lines contain apostrophes that make the
preprocessor print harmless "missing terminating '" warnings, which the script
discards.) A run produces byte-identical output to the committed `x86_64/*.def`.

## Provenance

- **Upstream:** the MinGW-w64 project, `mingw-w64-crt/` tree.
- **Source files:**
  `lib-common/{kernel32,ucrtbase,ucrtbase-common,ntdll,user32}.def.in`,
  the flat `lib-common/{bcrypt,gdi32,shell32,winmm,opengl32}.def`, and
  `def-include/{func,crt-aliases}.def.in`.
- **Fetched from:** the `mirror/mingw-w64` GitHub mirror, all files at the same
  pinned commit `93f3505a758fe70e56678f00e753af3bc4f640bb` (`master`).
- **Modifications:** none to the `src/` templates. The `x86_64/*.def` files are
  the mechanical preprocessor output described above (no manual symbol edits).

To refresh against a newer MinGW-w64 release, re-fetch the `src/` files from the
matching upstream tag, then run `./regenerate.sh` and review the diff.

## License / attribution

These export lists come from the MinGW-w64 runtime, whose license is reproduced
verbatim in [`COPYING.MinGW-w64-runtime.txt`](./COPYING.MinGW-w64-runtime.txt).
The MinGW-w64 runtime is open-source and FSF-certified GPL-compatible; the
overall notice permits redistribution in source and binary forms provided the
copyright notice, conditions, and disclaimer are retained — which this directory
does by shipping the full license text alongside the files.

## Note on tracking under `bin/`

`bin/` is `.gitignore`d, but bundled tooling/data here is force-added (the same
pattern as `bin/lld-link.exe`, `bin/nasm/...`). When committing, add these
explicitly:

    git add -f bin/windows-cross/def

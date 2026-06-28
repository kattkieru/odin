# cgltf cross demo — interactive console glTF inspector

A renderer-free console program that cross-compiles on a non-Windows host
against the **static** `vendor:cgltf` library and, on Windows, runs as an
interactive glTF inspector.

This is the cleanest probe of **static `.lib` + libc/`ucrtbase`
cross-linking**: `cgltf.lib` is MSVC-compiled and pulls a slice of the C runtime
(`malloc`/`free`, `fopen`/`fread`/`fseek`, `atof`/`atoi`, `str*`, the
stack-cookie / `/GS` helpers), so the produced `.exe` resolves all of it from the
bundled redistributable UCRT (`ucrtbase.dll`) plus the compiler-rt MSVC
CRT-support stubs — **with no static MSVC CRT (`libcmt`)**.

## Files

- `cgltf_inspector.odin` — the demo (parser + buffer load + console REPL).
- `assets/box.gltf` — a tiny, self-contained ASCII glTF (≈2 KB). One scene, one
  node, one mesh (a single triangle), one PBR material, four accessors, and one
  animation channel (so every browse category is non-empty). The geometry buffer
  is an inline base64 `data:` URI, so there is exactly one file and no external
  `.bin` to resolve at runtime.

## Build (Linux/macOS host → Windows `.exe`)

```sh
odin build tests/cross/vendor/cgltf -target:windows_amd64 -out:cgltf_inspector.exe
```

Produces a self-contained **PE32+ console** executable. No Windows SDK, no
`link.exe`, no extra flags — the bundled `bin/windows-cross/` toolchain supplies
`lld-link`, the import libs (incl. `ucrtbase.lib`), and the compiler-rt builtins.

`cgltf` is a **static** library, so its code is baked into the
`.exe`. **No DLLs are required** (running `tests/cross/vendor/stage-dlls.sh cgltf
<dir>` is a harmless no-op).

### Why the explicit `system:ucrtbase.lib` import

`vendor/cgltf/cgltf.odin` only `foreign import`s `cgltf.lib`. The cross linker
names a `system:` import lib only when an Odin package keeps a *live* reference to
it, so the demo itself `foreign import`s `system:ucrtbase.lib` and routes cgltf's
allocator through its `malloc`/`free`. Without that, the unreferenced UCRT import
would be pruned and cgltf's libc symbols would link-fail. (Guarded
`when ODIN_OS == .Windows`; on other targets cgltf's libc is the platform libc.)

## Run (manual Windows test)

Copy the `assets/` directory next to the `.exe`, then run:

```
cgltf_inspector.exe
# or with an explicit model path:
cgltf_inspector.exe path\to\model.gltf
```

It parses the model, loads its buffers, prints a summary, then drops into a REPL:

```
gltf> s        scenes      (s 0 for detail)
gltf> n        nodes       (n 0 for detail)
gltf> m        meshes
gltf> t        materials
gltf> a        accessors
gltf> c        animations (channels)
gltf> ?        help
gltf> q        quit
```

Each command lists the category; appending an index (e.g. `m 0`) prints detail.

## Verification (structural checks)

```sh
llvm-readobj --file-headers --coff-imports cgltf_inspector.exe
```

Expected: `Format COFF-x86-64`, `Magic 0x20B` (PE32+), `Subsystem
IMAGE_SUBSYSTEM_WINDOWS_CUI` (console); imported DLLs limited to system DLLs +
`ucrtbase.dll` (cgltf is statically linked, so it is *not* an import); and **no
`libcmt` / `msvcrt` / `vcruntime`**.

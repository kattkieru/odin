# box2d cross-build demo

An interactive physics sandbox cross-compiled on Linux to a Windows `amd64`
executable. It combines the **static** `vendor:box2d` library (simulation) with
the **shared** `vendor:raylib` library (rendering + input) in a single cross
link.

## What it does

A single 900x640 window (target 60 FPS) running a real box2d simulation:

- A `b2World` with downward gravity and a static **ground + two side walls**.
- **Left click** spawns a dynamic box or circle at the cursor; bodies fall,
  stack, and collide.
- **Left click + drag** on an existing body grabs it (overlap query under the
  cursor) and steers it toward the mouse; release to drop.
- **TAB** toggles the spawn shape between box and circle (a translucent preview
  follows the cursor).
- **Right click** / **C** / **R** clears all dynamic bodies.
- Fixed-timestep `b2World_Step` (1/60 s, 4 sub-steps) each frame; every body is
  rendered with raylib using its box2d transform, with on-screen help text and
  `DrawFPS`.

No bundled assets are needed (pure shapes).

## Why these two defines

```sh
-define:RAYLIB_SHARED=true -define:VENDOR_BOX2D_ENABLE_AVX2=false
```

- **`-define:RAYLIB_SHARED=true`** — `vendor/raylib` defaults to the **static**
  library (built against the MSVC static CRT, `/NODEFAULTLIB:libcmt`), which the
  Linux cross toolchain does not provide. The shared variant selects
  `windows/raylibdll.lib` -> `raylib.dll` and flips `/NODEFAULTLIB` to `msvcrt`.
  raylib also brings the windowing/CRT/system-lib side
  (`winmm`/`gdi32`/`user32`/`shell32`, provided by the bundled import
  libs); `raylib.dll` resolves those system DLLs itself at runtime, so they do
  not appear in this exe's import table.
- **`-define:VENDOR_BOX2D_ENABLE_AVX2=false`** — `vendor/box2d` picks its
  link target as `box2d_windows_amd64_{avx2,sse2}.lib`, defaulting to whichever
  the host/target CPU feature set implies. The manual test runs on an unknown
  Windows machine, so this demo pins the **sse2** baseline, which runs
  everywhere. (The avx2 variant links fine too on an avx2-capable target; this
  is portability, not a link requirement.)

box2d is a **static** `.lib`, so it is linked **into** the `.exe` and does **not**
appear in the import table. It is CRT-light: its libc dependency
(`malloc`/`free` via `ucrtbase.dll`) is kept on the link line by routing box2d's
allocator through ucrt (`box2d_demo_windows.odin`); its static-CRT-internal
symbols (`__security_cookie`, `__GSHandlerCheck`, ...) are satisfied by the
bundled compiler-rt CRT-support stubs. No Windows SDK is used.

## Cross-build

```sh
odin build tests/cross/vendor/box2d -out:box2d_demo.exe \
    -target:windows_amd64 -define:RAYLIB_SHARED=true \
    -define:VENDOR_BOX2D_ENABLE_AVX2=false
```

Produces a PE32+ **console** executable.

## Required runtime DLL

box2d is static (no DLL); the demo renders with shared raylib, so `raylib.dll`
is the only runtime DLL it needs.

| DLL          | Source (repo-relative)             |
| ------------ | ---------------------------------- |
| `raylib.dll` | `vendor/raylib/windows/raylib.dll` |

(See `dlls.txt`, consumed by `../stage-dlls.sh`.)

## Staging + manual run (Windows)

```sh
# after the cross-build, stage the DLL next to the .exe:
tests/cross/vendor/stage-dlls.sh box2d <outdir>
```

The expected layout on Windows is:

```
<outdir>/
  box2d_demo.exe
  raylib.dll
```

Then run `box2d_demo.exe`. The interactive on-Windows run (spawn/drag bodies,
observe gravity + collisions) is the manual test.

## Structural verification (Linux)

```sh
llvm-readobj --file-headers --coff-imports box2d_demo.exe
```

- `Magic: 0x20B` (PE32+), `Machine: IMAGE_FILE_MACHINE_AMD64`.
- `Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI` (console).
- Imported DLLs: `raylib.dll` (via `raylibdll.lib`), `ucrtbase.dll` (box2d's
  libc), plus `KERNEL32.dll` / `bcrypt.dll`. **box2d is statically linked, so it
  is NOT in the import table.** **No `libcmt` / `msvcrt` / `vcruntime`.**
```

# raylib cross-build demo

An interactive raylib playground that is cross-compiled on Linux to a Windows
`amd64` executable, using the **shared** raylib variant.

## What it does

A single 800x600 window (target 60 FPS) exercising the breadth of raylib:

- **Keyboard input**: arrow keys / `WASD` move a gold player rectangle,
  `Space` plays the bundled sound, `R` resets, `Esc` / window-close quits.
- **Mouse input**: hold the left button to paint colored dots; the right button
  plays the sound; a circle follows the cursor and the position is shown in the
  HUD.
- **2D shapes**: framed canvas, crossing guide lines, filled/outlined
  rectangles, filled/outlined circles.
- **Text**: title, controls help line, and a live HUD.
- **Texture**: the bundled `assets/icon.png` (64x64 RGBA) drawn in the corner
  (falls back to a placeholder rectangle if it cannot be loaded).
- **Audio**: the bundled `assets/blip.wav` (~0.25 s 440 Hz tone). If the audio
  device or sound fails to load, the demo prints a console note and keeps
  running (no crash).
- **On-screen FPS** via `DrawFPS`.

## Why `-define:RAYLIB_SHARED=true`

`vendor/raylib/raylib.odin` defaults to the **static** library
(`windows/raylib.lib`), which was built against the MSVC **static** CRT
(`/NODEFAULTLIB:libcmt`) that the Linux cross toolchain does not provide.

Setting `-define:RAYLIB_SHARED=true` flips the binding to:

- `windows/raylibdll.lib` (the import library for `raylib.dll`), and
- `/NODEFAULTLIB:msvcrt` (the DLL variant's CRT expectation).

No binding change is required. The shared Windows block also references
`system:Winmm.lib`, `system:Gdi32.lib`, `system:User32.lib`, and
`system:Shell32.lib`; those import libraries are provided by the bundled
`bin/windows-cross/lib/` set. `raylib.dll` resolves those system
DLLs itself at runtime, so they do not appear in this exe's import table --
only `raylib.dll` (plus `KERNEL32.dll` / `bcrypt.dll`) does.

## Cross-build

```sh
odin build tests/cross/vendor/raylib -out:raylib_demo.exe \
    -target:windows_amd64 -define:RAYLIB_SHARED=true
```

Produces a PE32+ **console** executable.

## Required runtime DLL

| DLL          | Source (repo-relative)              |
| ------------ | ----------------------------------- |
| `raylib.dll` | `vendor/raylib/windows/raylib.dll`  |

(See `dlls.txt`, consumed by `../stage-dlls.sh`.)

## Staging + manual run (Windows)

```sh
# after the cross-build, stage the DLL next to the .exe:
tests/cross/vendor/stage-dlls.sh raylib <outdir>
```

The PNG/WAV assets are loaded **at runtime from disk**, so they are part of the
demo's staged files: copy the `assets/` folder next to `raylib_demo.exe`
(alongside `raylib.dll`) before running. The expected layout on Windows is:

```
<outdir>/
  raylib_demo.exe
  raylib.dll
  assets/
    icon.png
    blip.wav
```

Then run `raylib_demo.exe`. Verify the window, input, shapes/text/texture,
audio, and FPS on Windows.

## Structural verification (Linux)

```sh
llvm-readobj --file-headers --coff-imports raylib_demo.exe
```

- `Magic: 0x20B` (PE32+), `Machine: IMAGE_FILE_MACHINE_AMD64`.
- `Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI` (console).
- Imported DLLs include `raylib.dll` (via `raylibdll.lib`); also `KERNEL32.dll`
  and `bcrypt.dll`. **No `libcmt` / `msvcrt` / `vcruntime`** (the
  `/NODEFAULTLIB:msvcrt` flip applies).

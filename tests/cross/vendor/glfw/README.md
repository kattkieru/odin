# GLFW + OpenGL cross-build demo

An interactive GLFW + OpenGL window demo that foreign-imports `vendor:glfw`
built with **`-define:GLFW_SHARED=true`**. The shared define selects the **DLL
import library** `vendor/glfw/lib/glfw3dll.lib` (which resolves against
`vendor/glfw/lib/glfw3.dll` at runtime) instead of the static
`glfw3_mt.lib` that the binding uses by default. GL entry points are loaded
dynamically through GLFW's proc-address getter via `vendor:OpenGL`, so the
produced `.exe` does **not** statically import `opengl32.dll`.

The demo:

- opens an 800x600 resizable window with a **GL 3.3 core** context,
- registers GLFW input **callbacks** (key / mouse-button / cursor-pos /
  framebuffer-size), logging each to the console,
- renders an animated time-based clear colour plus a single colored triangle
  (inline VAO/VBO + a trivial vertex/fragment shader) that rotates over time;
  rotation speed tracks the cursor X position.

**Controls:** `Esc` closes the window, `Space` or `W` toggles wireframe mode,
mouse buttons/motion and window resizes are logged. The window is created on the
**console** subsystem so `core:fmt` event logs are visible while
GLFW owns the window.

## Why `-define:GLFW_SHARED=true` is required

`vendor/glfw/constants.odin` sets `GLFW_SHARED :: #config(GLFW_SHARED, false)`,
so the GLFW binding **defaults to the static library** (`glfw3_mt.lib`). That
static lib expects to be linked against the MSVC static CRT, which the bundled
cross toolchain does not provide. Building with `-define:GLFW_SHARED=true`
selects the Windows shared block in `vendor/glfw/bindings/bindings.odin`, which
imports `../lib/glfw3dll.lib` plus `system:user32.lib`, `system:gdi32.lib`, and
`system:shell32.lib` (the bundled import libs).

## Cross-build (Linux host -> Windows `.exe`)

```sh
odin build tests/cross/vendor/glfw -out:glfw_demo.exe \
    -target:windows_amd64 -define:GLFW_SHARED=true
```

This produces a PE32+ **console** executable that imports `glfw3.dll` via
`glfw3dll.lib`. Because `glfw3.dll` carries its own C runtime and resolves its
own system dependencies (`user32`/`gdi32`/...) at load time, the link needs only
`glfw3dll.lib` plus the Odin runtime libs and `ucrtbase.dll` (for `sinf`, used by
the animated clear colour) -- there is **no static MSVC CRT (`libcmt`)**.

Observed imports: `KERNEL32.dll`, `glfw3.dll`, `ucrtbase.dll`, `bcrypt.dll`
(the last from the Odin runtime's default random). `user32`/`gdi32`/`shell32`
are *available* via the shared binding's `system:` imports but only appear in
the import table if symbols from them are referenced directly; here `glfw3.dll`
resolves them itself at runtime, so they are not in this `.exe`'s import table.
**`opengl32.dll` is intentionally NOT imported** -- GL is loaded at runtime
through `glfw.GetProcAddress`.

## Required runtime DLL(s)

| DLL         | Source path                  |
| ----------- | ---------------------------- |
| `glfw3.dll` | `vendor/glfw/lib/glfw3.dll`  |

`opengl32.dll` ships with Windows and is never staged. `glfw3.dll` resolves its
own further dependencies at runtime, so only this one DLL needs staging.

## Run (manual Windows test)

Stage the DLL next to the built `.exe`, then run it on a Windows host:

```sh
# after building, e.g. with -out:<outdir>/glfw_demo.exe
tests/cross/vendor/stage-dlls.sh glfw <outdir>
# then on Windows:  <outdir>\glfw_demo.exe
```

Expected: a window opens with a GL context; a colored triangle spins over an
animated background; moving the mouse changes the spin speed; `Space`/`W`
toggles wireframe; key/mouse/resize events log to the console; `Esc` (or closing
the window) quits.

## Verification (structural, done on Linux)

```sh
llvm-readobj --file-headers --coff-imports glfw_demo.exe
```

- `Magic 0x20B` (PE32+), `Machine IMAGE_FILE_MACHINE_AMD64`.
- `Subsystem IMAGE_SUBSYSTEM_WINDOWS_CUI` (console).
- Imports include `glfw3.dll` (via `glfw3dll.lib`); no `libcmt` / `msvcrt`; no
  `opengl32.dll` (GL loaded dynamically).

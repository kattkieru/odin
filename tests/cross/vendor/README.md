# Vendor library cross-compilation demos

These demos exercise the bundled
`-target:windows_amd64` cross toolchain against the in-tree `vendor:` libraries,
producing PE/COFF `.exe` files on a non-Windows host. Each demo lives in its own
folder:

```
tests/cross/vendor/
  stage-dlls.sh        # DLL staging helper
  sdl3/   dlls.txt + demo source   (DLL-based)
  glfw/   dlls.txt + demo source   (DLL-based)
  raylib/ dlls.txt + demo source   (DLL-based)
  cgltf/  demo source              (static .lib, no DLLs)
  box2d/  dlls.txt + demo source   (static box2d .lib, rendered with shared raylib -> needs raylib.dll)
```

## DLL staging vs. static libs

Two kinds of vendor demo:

- **DLL-based** (SDL3, GLFW, raylib): cross-link against an *import* library
  (`.lib`), but at run time on Windows the matching `*.dll` must sit next to the
  produced `.exe`. Odin does not auto-copy DLLs, so you stage them
  with `stage-dlls.sh` before the manual Windows run.
- **Static** (cgltf): linked from a static `.lib`, so the code is
  baked into the `.exe`. It needs **no** DLL staging — running `stage-dlls.sh`
  for it is a harmless no-op.
- **Static + DLL** (box2d): box2d itself is a static `.lib` (baked into the
  `.exe`, no DLL), but the box2d demo renders with the *shared* raylib, so it
  still needs `raylib.dll` staged at run time. Its `dlls.txt` therefore lists
  `raylib.dll`.

## Staging the DLLs

After cross-building a DLL-based demo, copy its runtime DLL(s) next to the
`.exe`:

```sh
# Build (example):
./odin build tests/cross/vendor/sdl3 -target:windows_amd64 -out:/tmp/out/sdl3.exe

# Stage the demo's DLLs next to the .exe:
tests/cross/vendor/stage-dlls.sh sdl3 /tmp/out
#   -> copies vendor/sdl3/SDL3.dll into /tmp/out/

# Static demos are a clean no-op:
tests/cross/vendor/stage-dlls.sh cgltf /tmp/out
#   -> "[cgltf] static-only demo, no DLLs to stage"
```

`stage-dlls.sh <demo> <output-dir>` reads `tests/cross/vendor/<demo>/dlls.txt`
(a one-line-per-DLL manifest of repo-relative source paths) and copies each
listed DLL into `<output-dir>`. It resolves paths from its own location, so it is
cwd-independent; it is idempotent (overwrite-copy) and POSIX-shell.

### Required DLLs per demo

| Demo   | Kind   | Runtime DLL(s)                  | Manifest            |
| ------ | ------ | ------------------------------- | ------------------- |
| sdl3   | DLL    | `vendor/sdl3/SDL3.dll`          | `sdl3/dlls.txt`     |
| glfw   | DLL    | `vendor/glfw/lib/glfw3.dll`     | `glfw/dlls.txt`     |
| raylib | DLL    | `vendor/raylib/windows/raylib.dll` | `raylib/dlls.txt` |
| cgltf  | static | none                            | (no manifest)       |
| box2d  | static box2d + shared raylib | `vendor/raylib/windows/raylib.dll` | `box2d/dlls.txt` |

To add a DLL to a demo (or add a new DLL-based demo), drop a `dlls.txt` in that
demo's folder listing the repo-relative DLL source path(s) — one line each. No
change to the script is needed.

## CI vs. manual run

CI's compile-check only needs the import (`.lib`) side to resolve, so
it does **not** call `stage-dlls.sh`. DLL staging is purely for the developer's
manual Windows run, where the `.dll` must be present at run time.

## Automated host-side check (`check-vendor-demos.sh`)

`check-vendor-demos.sh` is the positive cross compile/link check. For each
of the five demos it cross-builds the `.exe` for `windows_amd64` from this
(non-Windows) host using only the bundled `bin/windows-cross/` toolchain + the
generated import libs (no Windows SDK, no DLL staging), then structurally
validates the result with `llvm-readobj`:

- **PE32+** (file-header `Magic 0x20B`), **AMD64**, **console subsystem**
  (`IMAGE_SUBSYSTEM_WINDOWS_CUI`);
- **no static MSVC CRT** import (`libcmt` / `msvcrt` / `vcruntime`) — the cross
  path links `/nodefaultlib`;
- the **expected imported DLLs** are present, and statically-linked libraries
  (cgltf, box2d) are **not** in the import table.

Run it from the repo root (the compiler finds `bin/windows-cross/lld-link`
automatically; `llvm-readobj` must be on `PATH` or set `LLVM_READOBJ`):

```sh
# build_odin.sh release once if `./odin` isn't built:
#   LLVM_CONFIG=<llvm-config> ./build_odin.sh release
ODIN=./odin bash tests/cross/vendor/check-vendor-demos.sh
```

It exits non-zero on any failing assertion. It is wired into CI
(`.github/workflows/nightly.yml`, Linux build job, after the import-lib +
compiler-rt generation) **alongside** — not replacing — the existing
`tests/cross/native_link_regression.sh` guardrail and `check_all.sh
windows-cross` type-check.

The per-demo expected imports the check enforces:

| Demo   | Build defines                                              | Imports include            | Statically linked (NOT imported) |
| ------ | --------------------------------------------------------- | -------------------------- | -------------------------------- |
| cgltf  | (none)                                                    | `ucrtbase.dll`             | cgltf                            |
| sdl3   | (none)                                                    | `SDL3.dll`                 | —                                |
| glfw   | `-define:GLFW_SHARED=true`                                | `glfw3.dll` (no `opengl32`)| —                                |
| raylib | `-define:RAYLIB_SHARED=true`                              | `raylib.dll`               | —                                |
| box2d  | `-define:RAYLIB_SHARED=true -define:VENDOR_BOX2D_ENABLE_AVX2=false` | `raylib.dll`, `ucrtbase.dll` | box2d                |

(`KERNEL32.dll` + `bcrypt.dll` are always present — the `core:sys/windows`
default link surface.)

The host-side check is **necessary supporting evidence, not conclusive**.
Only running each `.exe` on a real Windows machine proves the demos actually
work; that is the manual test below.

## Manual on-Windows smoke test (per demo)

For each demo: cross-build it (with its defines), `stage-dlls.sh` its runtime
DLL(s) (+ copy `assets/` for cgltf/raylib), copy the staged folder to a Windows
10/11 x64 machine, run the `.exe`, and observe the documented interactive
behavior. The build/run/verify detail per demo lives in each demo's
own `README.md`; the common procedure and expected behavior are consolidated
here.

Build + stage into an output dir on the Linux host (example for sdl3):

```sh
mkdir -p /tmp/out
./odin build tests/cross/vendor/sdl3 -target:windows_amd64 -out:/tmp/out/sdl3_demo.exe
tests/cross/vendor/stage-dlls.sh sdl3 /tmp/out      # copies SDL3.dll next to the exe
# copy /tmp/out to Windows, then run the exe there
```

### cgltf — console glTF inspector (static, no DLL)

- **Build**: `./odin build tests/cross/vendor/cgltf -target:windows_amd64 -out:<out>/cgltf_inspector.exe`
- **Stage**: `stage-dlls.sh cgltf <out>` is a no-op (static). **Copy `tests/cross/vendor/cgltf/assets/` next to the exe** (the demo loads `assets/box.gltf` at runtime).
- **Run** (`cmd.exe`/PowerShell in `<out>`): `cgltf_inspector.exe`
- **Observe**: it parses `assets/box.gltf`, prints a summary (1 scene / 1 node / 1 mesh / 1 material / 4 accessors / 1 animation), then a `gltf>` REPL. Try `s`, `n 0`, `m 0`, `t 0`, `a 2`, `c 0`, then `q`.
- **Expected**: no missing-DLL error; correct summary counts; sane output from
  each browse command; `q` exits cleanly (exit code 0).

### sdl3 — window + renderer (needs `SDL3.dll`)

- **Build**: `./odin build tests/cross/vendor/sdl3 -target:windows_amd64 -out:<out>/sdl3_demo.exe` (add `-define:DEMO_AUDIO=true` to also hear a 440 Hz tone)
- **Stage**: `stage-dlls.sh sdl3 <out>` → copies `SDL3.dll`
- **Run**: `sdl3_demo.exe`
- **Observe**: a resizable window opens; moving/clicking the mouse moves the follower rect and logs events to the console; `Space` toggles the static shapes; resizing logs the new size; `Esc` or closing the window quits. With audio, a continuous tone plays.
- **Expected**: the window opens without a missing-DLL error; mouse, keyboard,
  and resize events are logged and drawn; the audio build produces a tone; and
  `Esc` or close quits cleanly.

### glfw — GLFW + OpenGL (needs `glfw3.dll`)

- **Build**: `./odin build tests/cross/vendor/glfw -target:windows_amd64 -define:GLFW_SHARED=true -out:<out>/glfw_demo.exe`
- **Stage**: `stage-dlls.sh glfw <out>` → copies `glfw3.dll` (`opengl32.dll` ships with Windows; never staged)
- **Run**: `glfw_demo.exe`
- **Observe**: a window with a GL 3.3 context; a colored triangle spins over an animated background; moving the mouse changes the spin speed; `Space`/`W` toggles wireframe; key/mouse/resize events log to the console; `Esc`/close quits.
- **Expected**: a window and GL context open; the triangle and animated
  background render; the mouse changes spin speed; wireframe toggles; and
  `Esc` or close quits cleanly.

### raylib — 2D playground (needs `raylib.dll` + assets)

- **Build**: `./odin build tests/cross/vendor/raylib -target:windows_amd64 -define:RAYLIB_SHARED=true -out:<out>/raylib_demo.exe`
- **Stage**: `stage-dlls.sh raylib <out>` → copies `raylib.dll`. **Copy `tests/cross/vendor/raylib/assets/` next to the exe** (`icon.png` + `blip.wav` load at runtime).
- **Run**: `raylib_demo.exe`
- **Observe**: an 800x600 / 60 FPS window; arrow keys / `WASD` move the player rect; hold left mouse to paint dots; `Space`/right-click plays the WAV; `R` resets; the PNG texture, shapes, text, and on-screen FPS all draw; `Esc`/close quits. A missing asset or audio device degrades to a console note (no crash).
- **Expected**: the window opens; input moves the player and paints dots;
  texture, text, and FPS render; sound plays when a device is available; and
  `Esc` or close quits cleanly.

### box2d — physics sandbox (static box2d, needs `raylib.dll`)

- **Build**: `./odin build tests/cross/vendor/box2d -target:windows_amd64 -define:RAYLIB_SHARED=true -define:VENDOR_BOX2D_ENABLE_AVX2=false -out:<out>/box2d_demo.exe`
- **Stage**: `stage-dlls.sh box2d <out>` → copies `raylib.dll` (box2d is static; raylib renders it)
- **Run**: `box2d_demo.exe`
- **Observe**: a 900x640 / 60 FPS window with a ground + two walls; left-click spawns falling boxes/circles that collide; left-click + drag grabs and steers a body; `TAB` toggles the spawn shape (translucent preview); right-click / `C` / `R` clears bodies; gravity + collisions are simulated each frame.
- **Expected**: the window opens; bodies spawn and fall; gravity and collisions
  behave correctly; drag-to-move and shape toggle work; and clear and quit work
  cleanly.

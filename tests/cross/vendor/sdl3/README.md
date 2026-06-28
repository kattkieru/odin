# SDL3 cross-build demo

An interactive SDL3 window/renderer demo that foreign-imports the **DLL import
library** `vendor:sdl3` (`vendor/sdl3/SDL3.lib`) and runs against
`vendor/sdl3/SDL3.dll` at runtime (DLL/import-lib variant).

The demo opens a single resizable window with an SDL renderer and runs an event
loop:

- **Quit / window close** -> exit.
- **Keyboard** (`KEY_DOWN`/`KEY_UP`): `Esc` quits, `Space` toggles the extra
  static shapes; events are logged to the console.
- **Mouse** (`MOUSE_MOTION` / `MOUSE_BUTTON_DOWN`/`UP`): a small filled rect
  follows the cursor; button/drag events are logged.
- **Window** (`WINDOW_RESIZED` / `WINDOW_PIXEL_SIZE_CHANGED`): logged.

Each frame clears, draws a border rect, two crossing lines, a static filled
rect (toggleable) and the mouse-follower rect, then presents. The window is
created on the **console** subsystem so `core:fmt` event logs are
visible while SDL opens its own window.

## Cross-build (Linux host -> Windows `.exe`)

```sh
odin build tests/cross/vendor/sdl3 -target:windows_amd64
```

This produces a PE32+ **console** executable that imports `SDL3.dll` via
`SDL3.lib`. Because `SDL3.dll` carries its own C runtime and resolves its own
system dependencies at load time, the default link needs only `SDL3.lib` plus
the Odin runtime libs -- there is **no static MSVC CRT (`libcmt`)** and no
extra system import libs.

Default-build imports: `KERNEL32.dll`, `SDL3.dll`, `bcrypt.dll` (the last from
the Odin runtime's default random).

## Optional audio tone

A 440 Hz sine tone is compiled in only with:

```sh
odin build tests/cross/vendor/sdl3 -target:windows_amd64 -define:DEMO_AUDIO=true
```

Audio is **off by default** so the default build/link surface stays minimal. The
tone is generated via an `SDL_AudioStream`; a failed audio open degrades to a
console warning rather than a crash. The audio build additionally imports
`ucrtbase.dll` (for `sinf`, used by the tone generator) -- still no `libcmt`.

## Required runtime DLL(s)

| DLL        | Source path             |
| ---------- | ----------------------- |
| `SDL3.dll` | `vendor/sdl3/SDL3.dll`  |

SDL3.dll resolves its own further dependencies (its CRT, system libs) at
runtime, so only this one DLL needs staging.

## Run (manual Windows test)

Stage the DLL next to the built `.exe`, then run it on a Windows host:

```sh
# after building, e.g. with -out:<outdir>/sdl3_demo.exe
tests/cross/vendor/stage-dlls.sh sdl3 <outdir>
# then on Windows:  <outdir>\sdl3_demo.exe
```

Expected: a window opens; moving/clicking the mouse moves the follower rect and
logs events to the console; `Space` toggles the static shapes; `Esc` (or closing
the window) quits. With `-define:DEMO_AUDIO=true`, a 440 Hz tone plays.

## Verification (structural, done on Linux)

```sh
llvm-readobj --file-headers --coff-imports sdl3_demo.exe
```

- `Magic 0x20B` (PE32+), `Machine IMAGE_FILE_MACHINE_AMD64`.
- `Subsystem IMAGE_SUBSYSTEM_WINDOWS_CUI` (console).
- Imports include `SDL3.dll` (via `SDL3.lib`); no `libcmt` / `msvcrt`.

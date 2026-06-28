#!/usr/bin/env sh
#
# Generate the windows_amd64 import libraries (.lib) that the bundled cross
# linker (bin/windows-cross/lld-link) links against, from the vendored
# MinGW-w64 .def export lists in bin/windows-cross/def/x86_64/.
#
# This is an Odin-DISTRIBUTION PACKAGING step, not an end-user step: it runs once
# at release time on the Linux packaging host (which already has the pinned LLVM
# tooling), and the resulting .lib files are shipped inside the distribution. The
# link step on the user's machine then consumes the prebuilt .lib files and needs
# no dlltool / MSVC SDK.
#
# Reproducibility / version pinning:
#   The .lib files are emitted by `llvm-dlltool` from the SAME LLVM major the
#   Odin compiler and the bundled lld-link are pinned to (currently 20 -- see
#   ci/build_linux_static.sh and bin/windows-cross/README.md). Always generate
#   with the matching llvm-dlltool so the import libs, lld-link, and compiler-rt
#   stay in lock-step. Set DLLTOOL to override the tool (e.g. llvm-dlltool-20).
#
# Inputs:  ../def/x86_64/{kernel32,ucrtbase}.def   (from ../def/regenerate.sh)
# Outputs: ./{kernel32,ucrtbase}.lib               (shipped in this directory)
#
# Usage:   ./generate-import-libs.sh
#          DLLTOOL=llvm-dlltool-20 ./generate-import-libs.sh

set -eu

cd "$(dirname "$0")"

DEF_DIR="../def/x86_64"
# MinGW-w64 .def base names to turn into import libs (base set).
#   kernel32 : core Win32 (process/thread/file/memory/heap/stdio/exit/args)
#   ucrtbase : UCRT redistributable (linked only on demand; see lib/README.md)
#   bcrypt   : BCryptGenRandom -- base/runtime's default random (always pulled by
#              a default core:sys/windows / core:fmt+core:os program)
#   ntdll    : RtlGetVersion -- core:sys/info / core:os OS-version queries
# bcrypt + ntdll are required for a flag-free default cross link (no
# -windows-sysroot / -extra-linker-flags workaround).
#
# Vendor-demo set: system DLLs pulled by vendor:raylib / vendor:glfw.
#   user32   : windowing (CreateWindowExW/GetMessageW) -- raylib + glfw
#   gdi32    : GDI device contexts (CreateCompatibleDC) -- raylib + glfw
#   shell32  : shell integration (ShellExecuteW)        -- raylib + glfw
#   winmm    : multimedia timing (timeGetTime)          -- raylib
#   opengl32 : GL/WGL entry points (wglCreateContext)   -- bundled for
#              completeness / future GL-direct demos (no current demo links it;
#              vendor:OpenGL loads GL via a proc-address callback).
#
# "Add on demand": when a future link surfaces another missing system DLL, add
# its base name here AND to ../def/regenerate.sh (and drop the MinGW-w64 source
# into ../def/src/), then re-run both scripts.
DLLS="kernel32 ucrtbase bcrypt ntdll user32 gdi32 shell32 winmm opengl32"

# Locate llvm-dlltool. Prefer an explicit $DLLTOOL, then the versioned name that
# matches the pinned LLVM major, then the unversioned name.
find_dlltool() {
    if [ -n "${DLLTOOL:-}" ]; then
        printf '%s\n' "$DLLTOOL"
        return 0
    fi
    for cand in llvm-dlltool-20 llvm-dlltool; do
        if command -v "$cand" >/dev/null 2>&1; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

if ! TOOL="$(find_dlltool)"; then
    echo "error: llvm-dlltool not found." >&2
    echo "  Install the LLVM tools matching the pinned major (20), or set" >&2
    echo "  DLLTOOL=/path/to/llvm-dlltool and re-run." >&2
    exit 1
fi

if ! command -v "$TOOL" >/dev/null 2>&1; then
    echo "error: configured DLLTOOL '$TOOL' is not executable / not found." >&2
    exit 1
fi

echo "using $TOOL ($("$TOOL" --version 2>/dev/null | head -n1 || echo 'version unknown'))"

for name in $DLLS; do
    def="${DEF_DIR}/${name}.def"
    lib="./${name}.lib"
    if [ ! -f "$def" ]; then
        echo "error: missing input .def: $def" >&2
        echo "  Run ../def/regenerate.sh first (see def/README.md)." >&2
        exit 1
    fi
    # -m i386:x86-64 : emit an amd64 (x86-64) COFF import library.
    # -d <def>       : input module-definition file (LIBRARY/EXPORTS list).
    # -l <lib>       : output MSVC-style import library lld-link consumes.
    "$TOOL" -m i386:x86-64 -d "$def" -l "$lib"
    echo "wrote ${lib} ($(wc -c < "$lib") bytes)"
done

echo "done: generated import libs for: $DLLS"

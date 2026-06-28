#!/usr/bin/env sh
#
# Regenerate the resolved, per-architecture .def files under x86_64/ from the
# vendored MinGW-w64 .def.in sources in src/.
#
# MinGW-w64 ships its export lists as C-preprocessor templates (*.def.in) that
# select symbols per target architecture via DEF_<ARCH> macros (see
# src/def-include/func.def.in). This script reproduces MinGW-w64's own build
# step: run the C preprocessor with the target arch macro defined and the
# def-include search path, then drop blank lines. The ';'-comment lines and the
# 'alias == real' EXPORTS aliases are passed through untouched (the C
# preprocessor only acts on '#' directives).
#
# Usage:  ./regenerate.sh            # regenerates x86_64/{kernel32,ucrtbase}.def
#
# Requires: a C preprocessor (cc/gcc/clang -E). No LLVM tooling needed here;
# validation with llvm-dlltool happens in the import-library generation step.

set -eu

cd "$(dirname "$0")"

CPP="${CC:-cc}"
SRC=src
INC=src/def-include

# arch -> DEF_<ARCH> macro  (only x86_64 is generated)
#
# Some MinGW-w64 export lists ship as C-preprocessor templates (*.def.in, e.g.
# kernel32/ucrtbase/ntdll), others as plain *.def with no arch macros (e.g.
# bcrypt, which lives in upstream lib-common/ as a flat .def). The plain ones
# pass through the same cpp pipeline unchanged (no '#' directives to act on), so
# a single code path handles both: prefer src/<name>.def.in, fall back to
# src/<name>.def.
gen() {
    arch_dir="$1"   # output subdir, e.g. x86_64
    def_macro="$2"  # MinGW-w64 arch macro, e.g. DEF_X64
    name="$3"       # def base name, e.g. kernel32

    if [ -f "${SRC}/${name}.def.in" ]; then
        in="${SRC}/${name}.def.in"
    elif [ -f "${SRC}/${name}.def" ]; then
        in="${SRC}/${name}.def"
    else
        echo "error: no source for '${name}' (looked for ${SRC}/${name}.def.in and ${SRC}/${name}.def)" >&2
        exit 1
    fi

    mkdir -p "$arch_dir"
    # -xc: treat .def(.in) as C source; -nostdinc: no system headers;
    # -P: no line markers. 2>/dev/null: MinGW-w64 sources contain apostrophes
    # inside ';' comments which make cpp emit harmless "missing terminating '"
    # warnings; the comment text passes through unchanged.
    "$CPP" -E -xc -nostdinc -P "-D${def_macro}" "-I${INC}" \
        "${in}" 2>/dev/null \
        | grep -v '^[[:space:]]*$' \
        > "${arch_dir}/${name}.def"
    echo "wrote ${arch_dir}/${name}.def ($(grep -c . "${arch_dir}/${name}.def") lines)"
}

# Base set: kernel32 + ucrtbase (Win32 + UCRT), plus bcrypt (BCryptGenRandom,
# pulled by base/runtime's default random) and ntdll (RtlGetVersion, pulled by
# core:sys/info / core:os version queries). bcrypt/ntdll are required for a
# flag-free default core:sys/windows cross link.
#
# Vendor-demo set: user32/gdi32/shell32/winmm are pulled by the
# windowing/GDI/shell/multimedia-timing system: lines of vendor:raylib and
# vendor:glfw; opengl32 is bundled for completeness / future GL-direct demos
# (the current demos load GL via a proc-address callback, so it is not on any
# present demo's link line). user32 ships as a MinGW-w64 .def.in template; the
# rest are flat lib-common .def files (same as bcrypt) — both flow through the
# same gen() path.
#
# "Add on demand": when a future link surfaces another missing system DLL, drop
# its MinGW-w64 src/<name>.def(.in) into src/ and add the base name to this list.
for name in kernel32 ucrtbase bcrypt ntdll user32 gdi32 shell32 winmm opengl32; do
    gen x86_64 DEF_X64 "$name"
done

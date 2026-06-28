#!/usr/bin/env sh
#
# Build libclang_rt.builtins-x86_64.a for x86_64-pc-windows-msvc.
# Use the LLVM major pinned by Odin. CLANG, LLVM_AR, LLVM_VERSION, and
# COMPILER_RT_SRC can override the default tools and source tree.

set -eu

cd "$(dirname "$0")"

# --- Configuration ---------------------------------------------------------

# Exact upstream compiler-rt release. Must match the pinned LLVM major (20).
LLVM_VERSION="${LLVM_VERSION:-20.1.8}"
TARGET="x86_64-pc-windows-msvc"
OUT_LIB="./libclang_rt.builtins-x86_64.a"

# --- Locate the toolchain --------------------------------------------------

find_tool() {
    # $1 = env override, $2.. = candidate names
    var="$1"; shift
    eval "val=\${$var:-}"
    if [ -n "${val:-}" ]; then printf '%s\n' "$val"; return 0; fi
    for cand in "$@"; do
        if command -v "$cand" >/dev/null 2>&1; then printf '%s\n' "$cand"; return 0; fi
    done
    return 1
}

if ! CLANG="$(find_tool CLANG clang-20 clang)"; then
    echo "error: clang not found. Install the LLVM/clang tools matching the" >&2
    echo "  pinned major (20), or set CLANG=/path/to/clang and re-run." >&2
    exit 1
fi
if ! LLVM_AR="$(find_tool LLVM_AR llvm-ar-20 llvm-ar)"; then
    echo "error: llvm-ar not found. Set LLVM_AR=/path/to/llvm-ar and re-run." >&2
    exit 1
fi

echo "using clang:  $CLANG ($("$CLANG" --version 2>/dev/null | head -n1 || echo '?'))"
echo "using ar:     $LLVM_AR"
echo "target:       $TARGET"
echo "llvm version: $LLVM_VERSION"

# --- Obtain the compiler-rt source -----------------------------------------

# Prefer an explicit source tree, then the vendored source, then a download.
VENDORED="../compiler-rt/builtins"
if [ -n "${COMPILER_RT_SRC:-}" ]; then
    BUILTINS="$COMPILER_RT_SRC/lib/builtins"
elif [ -d "$VENDORED" ]; then
    BUILTINS="$VENDORED"
else
    CACHE="./.compiler-rt-src"
    SRC="$CACHE/compiler-rt-${LLVM_VERSION}.src"
    if [ ! -d "$SRC" ]; then
        mkdir -p "$CACHE"
        tarball="$CACHE/compiler-rt-${LLVM_VERSION}.src.tar.xz"
        url="https://github.com/llvm/llvm-project/releases/download/llvmorg-${LLVM_VERSION}/compiler-rt-${LLVM_VERSION}.src.tar.xz"
        echo "downloading $url"
        if command -v curl >/dev/null 2>&1; then
            curl -fL -o "$tarball" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$tarball" "$url"
        else
            echo "error: need curl or wget to download compiler-rt source, or set" >&2
            echo "  COMPILER_RT_SRC=/path/to/extracted/compiler-rt-${LLVM_VERSION}.src" >&2
            exit 1
        fi
        tar xJf "$tarball" -C "$CACHE"
    fi
    BUILTINS="$SRC/lib/builtins"
fi

if [ ! -d "$BUILTINS" ]; then
    echo "error: compiler-rt builtins sources not found at: $BUILTINS" >&2
    exit 1
fi
echo "builtins src: $BUILTINS"

# --- Build --------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Minimal <stdlib.h> shim for int_util.c.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/stdlib.h" <<'EOF'
#ifndef _ODIN_CROSS_SHIM_STDLIB_H
#define _ODIN_CROSS_SHIM_STDLIB_H
#ifdef __cplusplus
extern "C" {
#endif
__declspec(noreturn) void abort(void);
#ifdef __cplusplus
}
#endif
#endif
EOF

CFLAGS="-O2 -fvisibility=hidden -fomit-frame-pointer -isystem $WORK/shim"

# Compile candidate builtins for the target and retain successful objects.
# Exclude CRT startup, EH, sanitizer, and profiling sources.
EXCLUDE="crtbegin.c crtend.c eprintf.c emutls.c enable_execute_stack.c gcc_personality_v0.c apple_versioning.c clear_cache.c os_version_check.c trampoline_setup.c"

is_excluded() {
    for e in $EXCLUDE; do [ "$1" = "$e" ] && return 0; done
    return 1
}

OBJDIR="$WORK/obj"
mkdir -p "$OBJDIR"

# Compile candidates in parallel; unsupported sources produce no object.
JOBS="${JOBS:-$( (nproc 2>/dev/null) || echo 4 )}"
compile_one() {
    src="$1"
    base="$(printf '%s' "$src" | tr '/' '_')"
    "$CLANG" --target="$TARGET" $CFLAGS -c "$BUILTINS/$src" -o "$OBJDIR/$base.o" 2>/dev/null || true
}

# Build the candidate source list (paths relative to $BUILTINS).
candidates=""
for path in "$BUILTINS"/*.c; do
    f="$(basename "$path")"
    if is_excluded "$f"; then continue; fi
    candidates="$candidates $f"
done
for f in x86_64/floatdidf.c x86_64/floatdisf.c x86_64/chkstk.S; do
    [ -f "$BUILTINS/$f" ] && candidates="$candidates $f"
done

running=0
for src in $candidates; do
    compile_one "$src" &
    running=$((running+1))
    if [ "$running" -ge "$JOBS" ]; then wait; running=0; fi
done
wait

ok="$(ls -1 "$OBJDIR"/*.o 2>/dev/null | wc -l | tr -d ' ')"
# Count candidates to report how many were skipped.
total=0; for src in $candidates; do total=$((total+1)); done
skip=$((total - ok))

if [ "$ok" -eq 0 ]; then
    echo "error: no builtin sources compiled -- toolchain/target problem?" >&2
    exit 1
fi

# compiler-rt provides ___chkstk_ms; expose the MSVC __chkstk name as an alias.
cat > "$WORK/chkstk_msvc.S" <<'EOF'
// __chkstk for the MSVC ABI (windows_amd64) -- alias of compiler-rt's
// ___chkstk_ms (same probe-only contract on x86-64). See generate-compiler-rt.sh.
#ifdef __x86_64__
.text
.balign 4
.globl __chkstk
__chkstk:
        jmp ___chkstk_ms
#endif
EOF
"$CLANG" --target="$TARGET" -c "$WORK/chkstk_msvc.S" -o "$OBJDIR/chkstk_msvc.S.o"
ok=$((ok+1))

# MSVC CRT support required by statically linked vendor libraries.
cat > "$WORK/msvc_crt_support.c" <<'EOF'
/* MSVC CRT-support stubs for the cross toolchain. See generate-compiler-rt.sh.
 * Built for x86_64-pc-windows-msvc; symbols match the MSVC ABI exactly. */
#if defined(__x86_64__)

/* MSVC default stack-cookie value. */
unsigned long long __security_cookie = 0x00002B992DDFA232ull;

/* MS CRT CPU-ISA dispatch level; 0 selects the baseline path. */
int __isa_available = 0;

/* __fastfail(code): immediate, non-returning process termination (int 0x29). */
static __attribute__((noreturn)) void crt_fastfail(unsigned int code) {
    __asm__ __volatile__("movl %0, %%ecx\n\tint $0x29" :: "r"(code) : "ecx");
    __builtin_unreachable();
}

/* __security_check_cookie(rcx = the frame's saved cookie). */
__attribute__((used))
void __security_check_cookie(unsigned long long cookie) {
    if (cookie != __security_cookie) {
        crt_fastfail(2 /* FAST_FAIL_STACK_COOKIE_CHECK_FAILURE */);
    }
}

/* __report_rangecheckfailure(): /RTCs / bounds-check failure. */
__attribute__((noreturn, used))
void __report_rangecheckfailure(void) {
    crt_fastfail(8 /* FAST_FAIL_RANGE_CHECK_FAILURE */);
}

/* __GSHandlerCheck: continue the SEH search for /GS frames. */
__attribute__((used))
int __GSHandlerCheck(void *ExceptionRecord, void *EstablisherFrame,
                     void *ContextRecord, void *DispatcherContext) {
    (void)ExceptionRecord; (void)EstablisherFrame;
    (void)ContextRecord; (void)DispatcherContext;
    return 1; /* EXCEPTION_CONTINUE_SEARCH */
}

#endif /* __x86_64__ */
EOF
"$CLANG" --target="$TARGET" -O2 -c "$WORK/msvc_crt_support.c" -o "$OBJDIR/msvc_crt_support.c.o"
ok=$((ok+1))

echo "compiled $ok objects (skipped $skip platform-inapplicable sources)"

rm -f "$OUT_LIB"
"$LLVM_AR" rcs "$OUT_LIB" "$OBJDIR"/*.o
echo "wrote $OUT_LIB ($(wc -c < "$OUT_LIB") bytes, $("$LLVM_AR" t "$OUT_LIB" | wc -l) objects)"

# Verify that required builtin symbols are present in the archive.
if command -v "${LLVM_NM:-llvm-nm}" >/dev/null 2>&1 || command -v llvm-nm-20 >/dev/null 2>&1; then
    NM="${LLVM_NM:-}"
    [ -n "$NM" ] || NM="$(command -v llvm-nm-20 || command -v llvm-nm)"
    REQUIRED="__chkstk ___chkstk_ms __udivti3 __umodti3 __divti3 __multi3 __compilerrt_abort_impl __fixunsdfdi __floattidf __security_check_cookie __security_cookie __report_rangecheckfailure __GSHandlerCheck __isa_available"
    missing=""
    syms="$("$NM" "$OUT_LIB" 2>/dev/null)"
    for s in $REQUIRED; do
        # Match a defined symbol named exactly $s. Code lives in text (T/t/W);
        # the MSVC CRT-support globals (__security_cookie, __isa_available) are
        # data (D/d/B/b), so accept those section letters too.
        printf '%s\n' "$syms" | grep -qE "[ ][TtWDdBb][ ]${s}\$" || missing="$missing $s"
    done
    if [ -n "$missing" ]; then
        echo "error: required builtins missing from $OUT_LIB:$missing" >&2
        echo "  (a source that should compile was silently skipped -- check the" >&2
        echo "  toolchain and the int_util.c stdlib shim.)" >&2
        exit 1
    fi
    echo "validation: required builtins present"
else
    echo "validation: skipped (no llvm-nm found; set LLVM_NM to enable)" >&2
fi

# Remove the downloaded source cache so it does not end up shipped in the
# distribution tarball (this dir is excluded from the Windows-binary strip).
# Keep it only when the caller supplied their own COMPILER_RT_SRC.
if [ -z "${COMPILER_RT_SRC:-}" ] && [ "${KEEP_SRC_CACHE:-0}" != "1" ]; then
    rm -rf ./.compiler-rt-src
fi

echo "done: generated compiler-rt builtins for $TARGET"

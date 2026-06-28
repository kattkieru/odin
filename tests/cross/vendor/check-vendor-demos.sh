#!/usr/bin/env bash
#
# Positive cross compile/link check for the vendor demos.
#
# For each of the five vendor demos (cgltf, sdl3, glfw, raylib, box2d) this
# script:
#   1. cross-builds it for -target:windows_amd64 from this (non-Windows) host,
#      using ONLY the bundled bin/windows-cross/ toolchain + generated import
#      libs (no Windows SDK, no DLL staging), with the demo's required defines;
#   2. structurally validates the produced .exe with llvm-readobj:
#        * PE32+        (file-headers Magic 0x20B)
#        * console      (Subsystem IMAGE_SUBSYSTEM_WINDOWS_CUI)
#        * NO libcmt / msvcrt / vcruntime import (the cross path is /nodefaultlib)
#        * the expected set of imported DLLs is present, and statically-linked
#          libraries (cgltf, box2d) are NOT in the import table.
#
# This is the automated host-side check; the interactive
# on-Windows runs are the remaining manual step (see README.md). It is wired into
# CI (.github/workflows/nightly.yml) ALONGSIDE the existing
# native_link_regression and check_all.sh windows-cross checks, never replacing
# them.
#
# It attempts every demo (so the log shows the full picture) and exits non-zero
# if any demo failed an assertion.
#
# Requirements on PATH: llvm-readobj (the bundled cross toolchain's lld-link is
# found automatically by the compiler from $ODIN_ROOT/bin/windows-cross/).
#
# Env:
#   ODIN          path to the odin compiler        (default: <repo>/odin)
#   LLVM_READOBJ  path to llvm-readobj             (default: llvm-readobj on PATH)
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

ODIN="${ODIN:-$REPO_ROOT/odin}"
LLVM_READOBJ="${LLVM_READOBJ:-llvm-readobj}"

if [[ ! -x "$ODIN" ]]; then
	echo "[check-vendor-demos] FAIL: odin compiler not found/executable: $ODIN" >&2
	exit 1
fi
if ! command -v "$LLVM_READOBJ" >/dev/null 2>&1; then
	echo "[check-vendor-demos] FAIL: llvm-readobj not found on PATH (set LLVM_READOBJ)." >&2
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Per-demo table. One entry per line:
#   <name>|<package dir, repo-relative>|<extra build defines>|<required DLLs, comma sep>|<demo-specific forbidden DLLs, comma sep>
# Required/forbidden DLL matching is case-insensitive. KERNEL32.dll and bcrypt.dll
# are always present (core:sys/windows default link surface) and need not be listed.
# The static MSVC CRT (libcmt/msvcrt/vcruntime) is forbidden for EVERY demo via
# GLOBAL_FORBIDDEN below, so only DEMO-SPECIFIC forbidden imports go here
# (opengl32 for glfw; the statically-linked vendor lib for cgltf/box2d).
DEMOS=(
	"cgltf|tests/cross/vendor/cgltf||ucrtbase.dll|cgltf"
	"sdl3|tests/cross/vendor/sdl3||SDL3.dll|"
	"glfw|tests/cross/vendor/glfw|-define:GLFW_SHARED=true|glfw3.dll|opengl32.dll"
	"raylib|tests/cross/vendor/raylib|-define:RAYLIB_SHARED=true|raylib.dll|"
	"box2d|tests/cross/vendor/box2d|-define:RAYLIB_SHARED=true -define:VENDOR_BOX2D_ENABLE_AVX2=false|raylib.dll|box2d"
)

# The /nodefaultlib invariant applies to EVERY demo: no static MSVC CRT may leak
# in. These are appended to each demo's forbidden set.
GLOBAL_FORBIDDEN="libcmt,msvcrt,vcruntime"

FAILURES=0

# Lowercase helper.
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Extract the imported DLL names (lowercased) from llvm-readobj --coff-imports.
# DLL names appear on lines of the form "  Name: <something>.dll"; symbol lines
# are "  Symbol: ...", so matching Name: lines that end in .dll is unambiguous.
imported_dlls() {
	local exe="$1"
	"$LLVM_READOBJ" --coff-imports "$exe" 2>/dev/null \
		| sed -n 's/^[[:space:]]*Name:[[:space:]]*\(.*\)$/\1/p' \
		| tr '[:upper:]' '[:lower:]' \
		| sort -u
}

check_demo() {
	local demo_config="$1"
	local name dir defines req_csv forbid_csv
	IFS='|' read -r name dir defines req_csv forbid_csv <<<"$demo_config"

	echo "=================================================================="
	echo "[check-vendor-demos] $name : odin build $dir -target:windows_amd64 $defines"

	local exe="$WORK/$name.exe"
	local log="$WORK/$name.build.log"

	# shellcheck disable=SC2086 -- $defines is an intentional word list.
	set +e
	"$ODIN" build "$REPO_ROOT/$dir" -out:"$exe" -target:windows_amd64 $defines >"$log" 2>&1
	local rc=$?
	set -e
	if [[ $rc -ne 0 ]]; then
		echo "[check-vendor-demos] $name FAIL: cross build returned $rc"
		echo "----- build output -----"; cat "$log"; echo "------------------------"
		FAILURES=$((FAILURES + 1))
		return
	fi
	if [[ ! -f "$exe" ]]; then
		echo "[check-vendor-demos] $name FAIL: build reported success but no exe at $exe"
		FAILURES=$((FAILURES + 1))
		return
	fi

	local demo_fail=0

	# --- PE32+ + console subsystem (file-headers) -------------------------
	local headers
	headers="$("$LLVM_READOBJ" --file-headers "$exe" 2>/dev/null)"
	if ! grep -q "Magic: 0x20B" <<<"$headers"; then
		echo "[check-vendor-demos] $name FAIL: not PE32+ (expected file-header Magic 0x20B)."
		demo_fail=1
	fi
	if ! grep -q "IMAGE_SUBSYSTEM_WINDOWS_CUI" <<<"$headers"; then
		echo "[check-vendor-demos] $name FAIL: not a console subsystem exe (expected IMAGE_SUBSYSTEM_WINDOWS_CUI)."
		demo_fail=1
	fi
	if ! grep -q "IMAGE_FILE_MACHINE_AMD64" <<<"$headers"; then
		echo "[check-vendor-demos] $name FAIL: wrong machine (expected IMAGE_FILE_MACHINE_AMD64)."
		demo_fail=1
	fi

	# --- imported DLLs ----------------------------------------------------
	local dlls
	dlls="$(imported_dlls "$exe")"

	# Required imports.
	if [[ -n "$req_csv" ]]; then
		local r
		IFS=',' read -ra REQ <<<"$req_csv"
		for r in "${REQ[@]}"; do
			[[ -z "$r" ]] && continue
			if ! grep -qx "$(lc "$r")" <<<"$dlls"; then
				echo "[check-vendor-demos] $name FAIL: expected import '$r' not in import table."
				demo_fail=1
			fi
		done
	fi

	# Forbidden imports (per-demo + global CRT invariant). Substring match so
	# 'vcruntime' catches vcruntime140.dll etc.
	local all_forbid="$forbid_csv,$GLOBAL_FORBIDDEN"
	local f
	IFS=',' read -ra FORB <<<"$all_forbid"
	for f in "${FORB[@]}"; do
		[[ -z "$f" ]] && continue
		if grep -q "$(lc "$f")" <<<"$dlls"; then
			echo "[check-vendor-demos] $name FAIL: forbidden import matching '$f' present in import table."
			demo_fail=1
		fi
	done

	if [[ $demo_fail -ne 0 ]]; then
		echo "----- imported DLLs -----"; echo "$dlls"; echo "-------------------------"
		FAILURES=$((FAILURES + 1))
	else
		echo "[check-vendor-demos] $name PASS: PE32+ console; imports = $(echo "$dlls" | tr '\n' ' ')"
	fi
}

for demo_config in "${DEMOS[@]}"; do
	check_demo "$demo_config"
done

echo "=================================================================="
if [[ $FAILURES -ne 0 ]]; then
	echo "[check-vendor-demos] FAIL: $FAILURES demo(s) failed their cross compile/link check."
	exit 1
fi
echo "[check-vendor-demos] PASS: all 5 vendor demos cross-build to valid PE32+ console exes."

#!/usr/bin/env sh
#
# Stage a vendor demo's runtime DLLs next to its cross-built .exe.
#
# The DLL-based vendor demos (SDL3, GLFW, raylib) link against an *import*
# library (.lib) at cross-link time, but at run time on Windows the matching
# *.dll must sit next to the produced .exe. Odin does not auto-copy DLLs,
# so this helper does it for the developer's manual
# Windows run. CI's compile-check only exercises the import (.lib) side and
# does NOT call this script (see README.md).
#
# Data-driven, per-demo manifest:
#   Each DLL-based demo dir carries a one-line-per-DLL manifest
#     tests/cross/vendor/<demo>/dlls.txt
#   listing the repo-relative source path of each DLL to copy, e.g.
#     vendor/sdl3/SDL3.dll
#   Adding a demo or a DLL is a one-line edit in that demo's own folder.
#
#   A static-only demo (cgltf) has NO dlls.txt -> running this script for
#   it is a clean no-op.
#
# Usage:
#   tests/cross/vendor/stage-dlls.sh <demo> <output-dir>
#
#     <demo>        demo name == tests/cross/vendor/<demo>/ folder name
#     <output-dir>  directory where the demo's .exe was built (DLLs copied here)
#
# Examples:
#   tests/cross/vendor/stage-dlls.sh sdl3  /tmp/out   # copies SDL3.dll  -> /tmp/out
#   tests/cross/vendor/stage-dlls.sh cgltf /tmp/out   # static-only: no-op, exit 0
#
# Behaviour: idempotent (overwrite-copy), POSIX-shell, no Odin-compiler changes.

set -eu

usage() {
    echo "usage: $0 <demo> <output-dir>" >&2
    echo "  <demo>       demo name (tests/cross/vendor/<demo>/)" >&2
    echo "  <output-dir> directory where the demo .exe was built" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

demo="$1"
outdir="$2"

# Resolve paths from this script's own location so the script is cwd-independent.
#   script_dir = .../tests/cross/vendor
#   repo_root  = .../  (three levels up: vendor -> cross -> tests -> root)
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/../../.." && pwd)"

manifest="$script_dir/$demo/dlls.txt"

# Static-only (no manifest) -> clean no-op so calling this for cgltf/box2d (or
# any not-yet-created demo) is harmless.
if [ ! -f "$manifest" ]; then
    echo "[$demo] static-only demo, no DLLs to stage"
    exit 0
fi

if [ ! -d "$outdir" ]; then
    echo "error: output dir does not exist: $outdir" >&2
    exit 1
fi

staged=0
# Read the manifest line by line. Skip blank lines and '#' comments so the
# manifest can carry an inline note if ever needed.
while IFS= read -r line || [ -n "$line" ]; do
    # Trim leading/trailing whitespace.
    dll_rel="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$dll_rel" in
        ''|'#'*) continue ;;
    esac

    src="$repo_root/$dll_rel"
    if [ ! -f "$src" ]; then
        echo "error: [$demo] manifest lists missing DLL: $dll_rel" >&2
        echo "  expected at: $src" >&2
        exit 1
    fi

    cp -f "$src" "$outdir/"
    echo "[$demo] staged $(basename "$dll_rel") -> $outdir/"
    staged=$((staged + 1))
done < "$manifest"

echo "[$demo] done: staged $staged DLL(s) into $outdir"

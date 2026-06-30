#!/usr/bin/env sh
#
# Provision the bundled Linux -> windows_amd64 cross-link toolchain into
# bin/windows-cross/ so the compiler can link windows_amd64 executables on a
# Linux host. This installs three things next to this script:
#
#   lld-link                          the PE/COFF linker (copied from the lld
#                                     toolchain on PATH)
#   lib/*.lib                         import libraries generated from the
#                                     vendored .def files (generate-import-libs.sh)
#   lib/libclang_rt.builtins-x86_64.a compiler-rt builtins (generate-compiler-rt.sh)
#
# It is idempotent: anything already present is kept. All inputs are vendored
# in-tree (the .def files and the compiler-rt builtins sources), so this runs
# fully offline.
#
# Requires an LLVM/lld toolchain on PATH (lld-link, llvm-dlltool, clang, llvm-ar)
# -- e.g. run inside the pixi environment (`pixi run provision-cross`).

set -eu

cd "$(dirname "$0")"
root=$(pwd)

# 1. lld-link binary.
if [ ! -x "$root/lld-link" ]; then
	src=$(command -v lld-link 2>/dev/null || true)
	if [ -z "$src" ]; then
		echo "provision: lld-link not found on PATH; install an LLVM/lld toolchain (or run inside the pixi env)" >&2
		exit 1
	fi
	cp "$src" "$root/lld-link"
	echo "provision: installed lld-link from $src"
else
	echo "provision: lld-link already present"
fi

# On macOS the lld-link executable from the Pixi environment depends on
# libraries beside it (libLLVM, libzstd, etc.). Copying it here leaves its
# original @loader_path/../lib rpath pointing at bin/lib instead of Pixi's
# local environment. Keep the copied linker usable from this checkout by
# adding a workspace-relative rpath. This is intentionally Darwin-only:
# Linux uses ELF loader metadata and does not need this adjustment.
if [ "$(uname -s)" = "Darwin" ]; then
	macos_pixi_lib_rpath='@loader_path/../../.pixi/envs/default/lib'
	if ! otool -l "$root/lld-link" | grep -F "path $macos_pixi_lib_rpath " >/dev/null; then
		install_name_tool -add_rpath "$macos_pixi_lib_rpath" "$root/lld-link"
		echo "provision: added Pixi library rpath to lld-link"
	else
		echo "provision: Pixi library rpath already present"
	fi
fi

# 2. Import libraries.
if [ ! -f "$root/lib/kernel32.lib" ]; then
	sh "$root/lib/generate-import-libs.sh"
else
	echo "provision: import libraries already present"
fi

# 3. compiler-rt builtins archive (downloads source on first run).
if [ ! -f "$root/lib/libclang_rt.builtins-x86_64.a" ]; then
	sh "$root/lib/generate-compiler-rt.sh"
else
	echo "provision: compiler-rt builtins already present"
fi

echo "provision: bin/windows-cross is ready"

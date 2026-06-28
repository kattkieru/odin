#!/usr/bin/env sh

# Strip Windows-HOST binaries from a non-Windows release artifact.
#
# Exception: bin/windows-cross/lib/ holds the windows_amd64 *import libraries*
# (kernel32.lib, ucrtbase.lib, ..., user32.lib/gdi32.lib/... ) the bundled cross
# linker needs. Those .lib files must SHIP in the Linux/macOS distribution even
# though they match the "*.lib"
# pattern below -- they are cross-compilation targets, not Windows-host binaries
# -- so that directory is excluded via the `! -path` guard. (The rest of
# bin/windows-cross/, e.g. lld-link.PLACEHOLDER, is still subject to stripping.)
#
# NOTE: `-prune` is intentionally NOT used here -- `find ... -delete` implies
# `-depth`, which disables `-prune`. The `! -path` predicate is the correct way
# to exclude a subtree from a `-delete` traversal.

find "$1" -type f \
	! -path '*/bin/windows-cross/lib/*' \
	\(\
	-iname "*.exe"           \
	-o -iname "*.dll"        \
	-o -iname "*.lib"        \
	-o -iname "*.pdb"        \
	-o -iname "*.PLACEHOLDER" \
    \) -delete

# Bundled cross-compilation linker (Linux host -> windows_amd64)

This directory ships the host-native (**Linux**) build of **`lld-link`**, the
LLVM PE/COFF linker, so that an Odin compiler running on Linux can link
`windows_amd64` executables with no Microsoft toolchain or SDK installed.

It mirrors how the Windows Odin distribution bundles `lld-link.exe` /
`wasm-ld.exe` / `nasm.exe` at the top of `bin/`, but the binary here is the
*Linux*-hosted `lld-link` that emits PE/COFF output.

## Contents

| File         | Description                                                       |
| ------------ | ----------------------------------------------------------------- |
| `lld-link`   | Linux-hosted LLVM PE/COFF linker (LLD). Emits `windows_amd64`.    |
| `LICENSE.TXT`| LLVM license (Apache License v2.0 with LLVM Exceptions).          |
| `def/`       | Vendored MinGW-w64 `.def` export lists for the system DLLs, used to generate `windows_amd64` import libs (see `def/README.md`). |
| `compiler-rt/` | Vendored LLVM `compiler-rt` builtins sources, compiled into the `windows_amd64` builtins archive (see `compiler-rt/README.md`). |
| `lib/`       | Generated `windows_amd64` link libraries: system-DLL import libs (`.lib`) and the compiler-rt builtins archive (`libclang_rt.builtins-x86_64.a`) consumed by `lld-link`, plus the packaging-time generators `generate-import-libs.sh` / `generate-compiler-rt.sh` (see `lib/README.md`). |
| `README.md`  | This file.                                                        |

## Version pinning

`lld-link` is pinned to the **same LLVM major** that the Odin compiler links
against (`LLVM-C`). At time of writing that major is **20** (see
`ci/build_linux_static.sh` and `.github/workflows/nightly.yml`, which build
against `llvm20`/`clang20`/`llvm-config-20`). Whenever the bundled `LLVM-C`
major is bumped, this `lld-link` must be re-provisioned from the matching LLVM
release so the linker and `compiler-rt`/import-lib generation stay consistent.

Confirm the bundled binary's version with:

    bin/windows-cross/lld-link --version

The reported "LLVM version" must match the compiler's LLVM major.

## Provenance / how to (re)provision the binary

The binary is taken from an **official upstream LLVM release** (not built from
source at Odin-packaging time), matching Odin's pinned LLVM major. For LLVM 20
the canonical source is the LLVM 20.1.x Linux x86_64 release tarball published
at:

    https://github.com/llvm/llvm-project/releases

Provisioning steps:

1. Download the Linux x86_64 `clang+llvm-<major>.<minor>.<patch>` release
   tarball (or your distribution's matching `lld` package).
2. Extract `bin/lld-link` from it.
3. Copy it to `bin/windows-cross/lld-link` and `chmod +x` it.
4. Because the repository's `.gitignore` ignores `bin/`, add it explicitly:

       git add -f bin/windows-cross/lld-link

5. Verify: `bin/windows-cross/lld-link --version`.

`lld-link` is a multi-call alias of the `lld` driver; some distributions ship a
single `lld` binary with `lld-link` as a symlink/hardlink. If you vendor such a
build, ship the resolved standalone `lld-link` (or both the driver and the
link) so the bundle is self-contained.

> `lld-link` is not stored in the repository. Provision the matching binary
> with the steps above before building a Windows target.

## Consumers

- The compiler builds and invokes the Windows linker command line on Linux
  using this binary.
- The toolchain resolver locates this binary at
  `$ODIN_ROOT/bin/windows-cross/lld-link`, replacing the Windows-only
  COM/registry discovery in `src/microsoft_craziness.h`.

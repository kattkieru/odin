# compiler-rt builtins (vendored source)

These are the LLVM `compiler-rt` **builtins** sources, used to build the
`windows_amd64` builtins archive (`../lib/libclang_rt.builtins-x86_64.a`) that
the bundled cross linker links against. They are vendored so the build is fully
offline — no download is needed.

- **Upstream:** LLVM release `llvmorg-20.1.8`, path `compiler-rt/lib/builtins/`.
  Pinned to the same LLVM major as the compiler, `lld-link`, and the import-lib
  generator.
- **Contents:** the portable top-level builtins sources/headers plus the
  `x86_64/` and `aarch64/` architecture directories. The other per-architecture
  directories (arm, i386, ppc, riscv, hexagon, avr, ve, loongarch, …) were
  removed to keep the vendored tree small; only `x86_64` is compiled today and
  `aarch64` is kept for a future arm64 target.
- **License:** Apache-2.0 WITH LLVM-exception — see `LICENSE.TXT` in this
  directory (and `../LICENSE.TXT`).
- **Regenerate the archive:** `../lib/generate-compiler-rt.sh` (uses this tree by
  default; set `COMPILER_RT_SRC` to point at a full source tree instead).

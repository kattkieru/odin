# Native-link regression guardrail

The cross-compilation work makes the PE/COFF (Windows) link path reachable from
non-Windows hosts. That work must be **purely additive**: a native build
(`Linux -> Linux`, `macOS -> macOS`, `Windows -> Windows`) must keep selecting
its native linker and keep producing the same structural link command line as
before.

These scripts enforce that invariant continuously in CI.

## What runs

- `native_link_regression.sh` — Linux/macOS. Run from anywhere:
  ```sh
  ODIN=./odin bash tests/cross/native_link_regression.sh
  ```
- `native_link_regression.ps1` — Windows:
  ```pwsh
  $env:ODIN = ".\odin.exe"; pwsh tests/cross/native_link_regression.ps1
  ```

Both build `hello.odin` natively with `-show-system-calls`, then check:

1. **Tier A (always enforced, no committed baseline required):**
   - the native build must NOT hit the cross-compile
     `"... not yet supported"` path that the cross-compilation work relaxes;
   - a native linker system call (`[SYSTEM CALL] *-link`) must be emitted;
   - the structural tokens that `src/linker.cpp` emits as string literals for
     the native link command must all be present;
   - the natively linked binary must run.

2. **Tier B (full normalized command-line baseline diff):**
   - the entire native link command line — with volatile pieces (absolute
     toolchain paths, temp object files, the output path, `ODIN_ROOT`, thread
     counts) normalized to placeholders — is diffed against a checked-in
     baseline under `baselines/`.
   - If no baseline exists for the host yet, one is auto-recorded and the run
     passes with a notice. Commit that file so subsequent runs diff against it.

## Updating the baseline

When you intentionally change the native link command line, regenerate and
commit the per-host baseline:

```sh
# Linux / macOS
ODIN=./odin bash tests/cross/native_link_regression.sh --update

# Windows
$env:ODIN = ".\odin.exe"; pwsh tests/cross/native_link_regression.ps1 -Update
```

Baselines are host-specific:

- `baselines/linux_native_link.txt`
- `baselines/darwin_native_link.txt`
- `baselines/windows_native_link.txt`

Because the exact command line depends on the runner's toolchain and default
library list, the committed baselines should be generated on a real build host
(CI auto-records one on first run on a fresh host, but a fresh CI checkout does
not persist it between runs). Tier A is the load-bearing guardrail and works
with no committed baseline at all.

package cross_check

// Curated package set for the Linux -> windows_amd64 cross-compile path.
// `check_all.sh windows-cross` type-checks this set for
// `-target:windows_amd64` from a Linux host to validate that the cross path holds
// beyond the single hello-world example.
//
// SCOPE: `core:fmt` + basic `core:os` and their CRT-free neighbours. The cross
// link is freestanding/no-CRT by design (see src/build_settings.cpp: a windows
// target on a non-Windows host forces `no_crt`), so packages that require the C
// runtime or a Windows SDK / native vendor library are deliberately EXCLUDED:
//
//   - `core:c/libc` (and anything importing it): `#assert(!ODIN_NO_CRT)` fires on
//     the cross path because the bundled toolchain ships no MSVC static CRT
//     (libcmt) / UCRT import lib.
//   - `vendor:*` native libraries (raylib / SDL / DirectX / ...): require native
//     import libs not bundled with the cross toolchain.
//
// This is why the cross check uses this curated set rather than `examples/all`,
// which intentionally imports every package (including `core:c/libc` and vendor)
// for the documentation generator and therefore cannot pass on the cross path.

@(require) import "core:fmt"
@(require) import "core:os"

@(require) import "core:mem"
@(require) import "core:io"
@(require) import "core:bytes"
@(require) import "core:bufio"

@(require) import "core:strings"
@(require) import "core:strconv"
@(require) import "core:unicode"
@(require) import "core:unicode/utf8"
@(require) import "core:unicode/utf16"

@(require) import "core:slice"
@(require) import "core:slice/heap"
@(require) import "core:sort"
@(require) import "core:container/queue"
@(require) import "core:container/small_array"

@(require) import "core:math"
@(require) import "core:math/bits"
@(require) import "core:math/linalg"

@(require) import "core:time"
@(require) import "core:sync"
@(require) import "core:thread"

@(require) import "core:encoding/json"
@(require) import "core:encoding/base64"
@(require) import "core:encoding/endian"
@(require) import "core:hash"
@(require) import "core:reflect"

@(require) import "core:sys/windows"

main :: proc() {}

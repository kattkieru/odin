package hello_cross

// End-to-end cross-build validation program.
//
// Cross-compiled on a Linux host with the bundled Windows toolchain:
//
//     odin build tests/cross/hello_cross.odin -file -target:windows_amd64
//
// produces a self-contained PE/COFF console .exe (no Windows SDK, no link.exe).
// It deliberately exercises both core:fmt (formatted stdout) and basic core:os
// (process args + explicit exit code via the Win32-direct core:os layer), so the
// produced binary covers the core surface the cross toolchain must support.

import "core:fmt"
import "core:os"

main :: proc() {
	fmt.println("hello from a Linux->Windows cross build")
	fmt.printfln("args: %d, first: %q", len(os.args), os.args[0])
	os.exit(0)
}

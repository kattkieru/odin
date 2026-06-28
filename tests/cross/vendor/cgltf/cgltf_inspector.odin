package cgltf_inspector

// Interactive console glTF inspector.
//
// A renderer-free demo that foreign-imports the *static* vendor:cgltf library
// (vendor/cgltf/lib/cgltf.lib), parses a bundled tiny ASCII glTF model, loads
// its buffers, and lets the user browse scenes / nodes / meshes / materials /
// accessors / animations from a console REPL.
//
// This is the cleanest probe of static-.lib + libc/ucrtbase cross-linking:
// cgltf is compiled by MSVC and pulls a slice of the C runtime (malloc/free,
// fopen/fread, strtod, str*), so the produced .exe must resolve those against
// the bundled ucrtbase import lib plus the compiler-rt MSVC CRT-support stubs --
// with no static MSVC CRT (libcmt).
//
// Cross-build (Linux host -> Windows .exe):
//
//     odin build tests/cross/vendor/cgltf -target:windows_amd64 \
//         -out:cgltf_inspector.exe
//
// produces a PE32+ *console* executable. For the manual Windows run, place the
// demo's assets/ directory next to the .exe (see README.md). No DLLs needed.

import "core:fmt"
import "core:os"
import "core:bufio"
import "core:strings"
import "vendor:cgltf"

// cgltf is compiled against the C runtime; on the Windows cross path those libc
// symbols (malloc/free, fopen/fread, strtod, str*) are resolved from the bundled
// redistributable UCRT (ucrtbase.dll). cgltf.odin only foreign-imports cgltf.lib,
// so on Windows we must name ucrtbase ourselves AND keep a live reference to it,
// otherwise the linker prunes the (un-referenced) import and cgltf's libc symbols
// go undefined. malloc/free double as cgltf's allocator callbacks below, which
// both documents the dependency and exercises it. On other targets cgltf's libc
// is the platform libc (linked automatically), so we use cgltf's default
// allocator and need no explicit import.
when ODIN_OS == .Windows {
	foreign import ucrt "system:ucrtbase.lib"

	@(default_calling_convention="c")
	foreign ucrt {
		malloc :: proc(size: uint) -> rawptr ---
		free   :: proc(ptr: rawptr) ---
	}

	ucrt_alloc :: proc "c" (user: rawptr, size: uint) -> rawptr {
		return malloc(size)
	}
	ucrt_free :: proc "c" (user: rawptr, ptr: rawptr) {
		free(ptr)
	}
}

DEFAULT_ASSET :: "assets/box.gltf"

main :: proc() {
	// Allow an explicit asset path as the first arg; default to the bundled one
	// (relative to the working directory / next to the .exe on Windows).
	path := DEFAULT_ASSET
	if len(os.args) > 1 {
		path = os.args[1]
	}

	fmt.println("=== Odin cross glTF inspector (vendor:cgltf, static .lib) ===")
	fmt.printfln("loading: %s", path)

	opts: cgltf.options
	when ODIN_OS == .Windows {
		// Route cgltf's allocations through ucrtbase, keeping the import live.
		opts.memory.alloc_func = ucrt_alloc
		opts.memory.free_func  = ucrt_free
	}

	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)

	model, res := cgltf.parse_file(opts, cpath)
	if res != .success {
		fmt.printfln("error: cgltf_parse_file failed: %v", res)
		fmt.println("(make sure the assets/ directory sits next to the executable)")
		os.exit(1)
	}
	defer cgltf.free(model)

	if buf_res := cgltf.load_buffers(opts, model, cpath); buf_res != .success {
		fmt.printfln("error: cgltf_load_buffers failed: %v", buf_res)
		os.exit(1)
	}

	if val_res := cgltf.validate(model); val_res != .success {
		fmt.printfln("warning: cgltf_validate reported: %v (continuing)", val_res)
	}

	fmt.printfln("loaded OK. asset version %q, generator %q",
		safe_cstr(model.asset.version), safe_cstr(model.asset.generator))
	print_summary(model)

	run_repl(model)
}

run_repl :: proc(model: ^cgltf.data) {
	sc: bufio.Scanner
	bufio.scanner_init(&sc, os.to_reader(os.stdin))
	defer bufio.scanner_destroy(&sc)

	print_help()
	for {
		fmt.print("\ngltf> ")
		if !bufio.scanner_scan(&sc) {
			fmt.println() // EOF / closed stdin -> clean exit
			break
		}
		line := strings.trim_space(bufio.scanner_text(&sc))
		if len(line) == 0 {
			continue
		}

		cmd := line[0]
		arg := strings.trim_space(line[1:])

		switch cmd {
		case 's': browse_scenes(model, arg)
		case 'n': browse_nodes(model, arg)
		case 'm': browse_meshes(model, arg)
		case 't': browse_materials(model, arg)
		case 'a': browse_accessors(model, arg)
		case 'c': browse_animations(model, arg)
		case '?', 'h': print_help()
		case 'q': fmt.println("bye"); return
		case: fmt.printfln("unknown command %q -- type ? for help", line)
		}
	}
}

print_help :: proc() {
	fmt.println("commands:")
	fmt.println("  s [i]  scenes      (optional index i for detail)")
	fmt.println("  n [i]  nodes")
	fmt.println("  m [i]  meshes")
	fmt.println("  t [i]  materials")
	fmt.println("  a [i]  accessors")
	fmt.println("  c [i]  animations (channels)")
	fmt.println("  ?      help")
	fmt.println("  q      quit")
}

print_summary :: proc(model: ^cgltf.data) {
	fmt.println("contents:")
	fmt.printfln("  scenes     %d", len(model.scenes))
	fmt.printfln("  nodes      %d", len(model.nodes))
	fmt.printfln("  meshes     %d", len(model.meshes))
	fmt.printfln("  materials  %d", len(model.materials))
	fmt.printfln("  accessors  %d", len(model.accessors))
	fmt.printfln("  animations %d", len(model.animations))
}

// --- category browsers ------------------------------------------------------

// parse_index returns (index, ok). ok is false when arg is empty (list mode).
parse_index :: proc(arg: string) -> (idx: int, ok: bool) {
	if len(arg) == 0 {
		return 0, false
	}
	n := 0
	for ch in arg {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		n = n*10 + int(ch - '0')
	}
	return n, true
}

browse_scenes :: proc(model: ^cgltf.data, arg: string) {
	if idx, ok := parse_index(arg); ok {
		if idx < 0 || idx >= len(model.scenes) {
			fmt.printfln("scene index out of range (0..%d)", len(model.scenes)-1)
			return
		}
		s := model.scenes[idx]
		fmt.printfln("scene[%d] %q: %d node(s)", idx, safe_cstr(s.name), len(s.nodes))
		for n in s.nodes {
			fmt.printfln("    node %d: %q", cgltf.node_index(model, n), safe_cstr(n.name))
		}
		return
	}
	fmt.printfln("%d scene(s):", len(model.scenes))
	for s, i in model.scenes {
		fmt.printfln("  [%d] %q  (%d root node(s))", i, safe_cstr(s.name), len(s.nodes))
	}
}

browse_nodes :: proc(model: ^cgltf.data, arg: string) {
	if idx, ok := parse_index(arg); ok {
		if idx < 0 || idx >= len(model.nodes) {
			fmt.printfln("node index out of range (0..%d)", len(model.nodes)-1)
			return
		}
		n := &model.nodes[idx]
		fmt.printfln("node[%d] %q", idx, safe_cstr(n.name))
		fmt.printfln("    translation %v", n.translation)
		fmt.printfln("    rotation    %v", n.rotation)
		fmt.printfln("    scale       %v", n.scale)
		fmt.printfln("    children    %d", len(n.children))
		if n.mesh != nil {
			fmt.printfln("    mesh        %d (%q)", cgltf.mesh_index(model, n.mesh), safe_cstr(n.mesh.name))
		}
		return
	}
	fmt.printfln("%d node(s):", len(model.nodes))
	for n, i in model.nodes {
		has_mesh := n.mesh != nil
		fmt.printfln("  [%d] %q  translation=%v  mesh=%v", i, safe_cstr(n.name), n.translation, has_mesh)
	}
}

browse_meshes :: proc(model: ^cgltf.data, arg: string) {
	if idx, ok := parse_index(arg); ok {
		if idx < 0 || idx >= len(model.meshes) {
			fmt.printfln("mesh index out of range (0..%d)", len(model.meshes)-1)
			return
		}
		m := &model.meshes[idx]
		fmt.printfln("mesh[%d] %q: %d primitive(s)", idx, safe_cstr(m.name), len(m.primitives))
		for p, pi in m.primitives {
			fmt.printfln("    primitive %d: type=%v, %d attribute(s), indices=%v",
				pi, p.type, len(p.attributes), p.indices != nil)
			for a in p.attributes {
				fmt.printfln("        attr %v[%d] -> accessor %d",
					a.type, a.index, cgltf.accessor_index(model, a.data))
			}
		}
		return
	}
	fmt.printfln("%d mesh(es):", len(model.meshes))
	for m, i in model.meshes {
		fmt.printfln("  [%d] %q  (%d primitive(s))", i, safe_cstr(m.name), len(m.primitives))
	}
}

browse_materials :: proc(model: ^cgltf.data, arg: string) {
	if idx, ok := parse_index(arg); ok {
		if idx < 0 || idx >= len(model.materials) {
			fmt.printfln("material index out of range (0..%d)", len(model.materials)-1)
			return
		}
		mt := &model.materials[idx]
		fmt.printfln("material[%d] %q", idx, safe_cstr(mt.name))
		fmt.printfln("    alpha_mode  %v", mt.alpha_mode)
		fmt.printfln("    double_sided %v", bool(mt.double_sided))
		if mt.has_pbr_metallic_roughness {
			pbr := mt.pbr_metallic_roughness
			fmt.printfln("    baseColor   %v", pbr.base_color_factor)
			fmt.printfln("    metallic    %v", pbr.metallic_factor)
			fmt.printfln("    roughness   %v", pbr.roughness_factor)
		}
		return
	}
	fmt.printfln("%d material(s):", len(model.materials))
	for mt, i in model.materials {
		base := mt.has_pbr_metallic_roughness ? mt.pbr_metallic_roughness.base_color_factor : [4]f32{}
		fmt.printfln("  [%d] %q  baseColor=%v", i, safe_cstr(mt.name), base)
	}
}

browse_accessors :: proc(model: ^cgltf.data, arg: string) {
	if idx, ok := parse_index(arg); ok {
		if idx < 0 || idx >= len(model.accessors) {
			fmt.printfln("accessor index out of range (0..%d)", len(model.accessors)-1)
			return
		}
		ac := &model.accessors[idx]
		fmt.printfln("accessor[%d] %q", idx, safe_cstr(ac.name))
		fmt.printfln("    type           %v", ac.type)
		fmt.printfln("    component_type %v", ac.component_type)
		fmt.printfln("    count          %d", ac.count)
		fmt.printfln("    normalized     %v", bool(ac.normalized))
		if bool(ac.has_min) {
			fmt.printfln("    min            %v", ac.min)
		}
		if bool(ac.has_max) {
			fmt.printfln("    max            %v", ac.max)
		}
		return
	}
	fmt.printfln("%d accessor(s):", len(model.accessors))
	for ac, i in model.accessors {
		fmt.printfln("  [%d] %q  %v/%v  count=%d", i, safe_cstr(ac.name), ac.type, ac.component_type, ac.count)
	}
}

browse_animations :: proc(model: ^cgltf.data, arg: string) {
	if idx, ok := parse_index(arg); ok {
		if idx < 0 || idx >= len(model.animations) {
			fmt.printfln("animation index out of range (0..%d)", len(model.animations)-1)
			return
		}
		an := &model.animations[idx]
		fmt.printfln("animation[%d] %q: %d channel(s), %d sampler(s)",
			idx, safe_cstr(an.name), len(an.channels), len(an.samplers))
		for ch, ci in an.channels {
			target := ch.target_node != nil ? safe_cstr(ch.target_node.name) : "<none>"
			interp := ch.sampler != nil ? fmt.tprintf("%v", ch.sampler.interpolation) : "?"
			fmt.printfln("    channel %d: path=%v target=%q interpolation=%s",
				ci, ch.target_path, target, interp)
		}
		return
	}
	fmt.printfln("%d animation(s):", len(model.animations))
	for an, i in model.animations {
		fmt.printfln("  [%d] %q  (%d channel(s))", i, safe_cstr(an.name), len(an.channels))
	}
}

// --- helpers ----------------------------------------------------------------

// safe_cstr renders a possibly-nil cgltf cstring as a stable string.
safe_cstr :: proc(s: cstring) -> string {
	if s == nil {
		return "<unnamed>"
	}
	return string(s)
}

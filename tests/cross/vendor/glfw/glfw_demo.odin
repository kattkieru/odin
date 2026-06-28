package glfw_demo

// Interactive GLFW + OpenGL window demo.
//
// Foreign-imports vendor:glfw built with -define:GLFW_SHARED=true, which selects
// the DLL import library vendor/glfw/lib/glfw3dll.lib (-> glfw3.dll at runtime)
// instead of the static glfw3_mt.lib default. The shared GLFW
// Windows binding also pulls system:user32.lib + system:gdi32.lib +
// system:shell32.lib, all provided by the bundled import libs.
//
// GL entry points are loaded dynamically through GLFW's proc-address getter
// (gl.load_up_to(3, 3, glfw.gl_set_proc_address)), so the produced .exe does
// NOT statically import opengl32.dll -- GL is resolved at runtime via GLFW.
//
// The demo:
//   - opens an 800x600 resizable window with a GL 3.3 core context,
//   - registers GLFW input *callbacks* (key / mouse-button / cursor-pos /
//     framebuffer-size), logging each to the console,
//   - renders an animated time-based clear colour plus a single colored
//     triangle (inline VAO/VBO + trivial vertex/fragment shader) that rotates
//     over time; the rotation speed tracks the cursor X position.
//   Controls: Esc closes the window, Space toggles wireframe mode, W also
//   toggles wireframe, mouse buttons are logged.
//
// Cross-build (Linux host -> Windows .exe):
//
//     odin build tests/cross/vendor/glfw -out:glfw_demo.exe \
//         -target:windows_amd64 -define:GLFW_SHARED=true
//
// produces a PE32+ *console* executable importing glfw3.dll (via glfw3dll.lib).
// The shared binding also references system:user32/gdi32/shell32, but glfw3.dll
// resolves those itself at runtime, so they do not appear in this exe's import
// table. For the manual Windows run, stage the DLL next to the .exe:
//
//     tests/cross/vendor/stage-dlls.sh glfw <outdir>
//
// then run glfw_demo.exe. See README.md.

import "base:runtime"
import "core:fmt"
import glfw "vendor:glfw"
import gl "vendor:OpenGL"

// The animated clear colour needs libc's sinf. glfw3dll.lib alone pulls no CRT
// (glfw3.dll carries its own), so on the Windows cross path name ucrtbase
// ourselves and keep sinf live -- the same pattern the sdl3/cgltf demos use for
// their libc surface. ucrtbase.dll exports sinf; on other targets sinf comes
// from the platform libc (linked automatically).
when ODIN_OS == .Windows {
	foreign import libc "system:ucrtbase.lib"
} else {
	foreign import libc "system:m"
}
@(default_calling_convention="c")
foreign libc {
	sinf :: proc(x: f32) -> f32 ---
}

WINDOW_W :: 800
WINDOW_H :: 600

GL_MAJOR :: 3
GL_MINOR :: 3

// Demo state shared with the GLFW callbacks via the window user pointer.
State :: struct {
	wireframe:    bool,
	cursor_x:     f64,
	cursor_y:     f64,
	fb_width:     i32,
	fb_height:    i32,
}

VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec3 a_col;
uniform float u_angle;
out vec3 v_col;
void main() {
	float c = cos(u_angle);
	float s = sin(u_angle);
	vec2 p = vec2(a_pos.x * c - a_pos.y * s,
	              a_pos.x * s + a_pos.y * c);
	gl_Position = vec4(p, 0.0, 1.0);
	v_col = a_col;
}
`

FRAGMENT_SHADER :: `#version 330 core
in vec3 v_col;
out vec4 frag_color;
void main() {
	frag_color = vec4(v_col, 1.0);
}
`

main :: proc() {
	fmt.println("GLFW + OpenGL cross-build demo")
	fmt.println("  Controls: Esc = quit, Space/W = toggle wireframe, move/click the mouse.")

	glfw.SetErrorCallback(error_callback)

	if !glfw.Init() {
		desc, code := glfw.GetError()
		fmt.eprintfln("glfwInit failed (%d): %s", code, desc)
		return
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, GL_MAJOR)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, GL_MINOR)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, true)
	glfw.WindowHint(glfw.RESIZABLE, true)

	window := glfw.CreateWindow(WINDOW_W, WINDOW_H, "Odin x GLFW + OpenGL (cross-built)", nil, nil)
	if window == nil {
		desc, code := glfw.GetError()
		fmt.eprintfln("glfwCreateWindow failed (%d): %s", code, desc)
		return
	}
	defer glfw.DestroyWindow(window)

	state := State{
		fb_width  = WINDOW_W,
		fb_height = WINDOW_H,
	}
	glfw.SetWindowUserPointer(window, &state)

	glfw.MakeContextCurrent(window)
	glfw.SwapInterval(1) // vsync

	// Load GL function pointers dynamically through GLFW (no static opengl32
	// import). This is why the produced .exe does not import opengl32.dll.
	gl.load_up_to(GL_MAJOR, GL_MINOR, glfw.gl_set_proc_address)

	// Input via GLFW callbacks.
	glfw.SetKeyCallback(window, key_callback)
	glfw.SetMouseButtonCallback(window, mouse_button_callback)
	glfw.SetCursorPosCallback(window, cursor_pos_callback)
	glfw.SetFramebufferSizeCallback(window, framebuffer_size_callback)

	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok {
		msg, _, link_msg, _ := gl.get_last_error_messages()
		fmt.eprintfln("shader build failed:\n  compile: %s\n  link: %s", msg, link_msg)
		return
	}
	defer gl.DeleteProgram(program)
	u_angle := gl.GetUniformLocation(program, "u_angle")

	// A single triangle: position (x, y) + colour (r, g, b), interleaved.
	vertices := [?]f32{
	//   x      y       r     g     b
		 0.0,   0.6,    1.0,  0.2,  0.2,
		-0.6,  -0.5,    0.2,  1.0,  0.2,
		 0.6,  -0.5,    0.2,  0.4,  1.0,
	}

	vao, vbo: u32
	gl.GenVertexArrays(1, &vao)
	gl.BindVertexArray(vao)
	gl.GenBuffers(1, &vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices[0], gl.STATIC_DRAW)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 5 * size_of(f32), 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 3, gl.FLOAT, false, 5 * size_of(f32), 2 * size_of(f32))
	gl.EnableVertexAttribArray(1)
	defer gl.DeleteVertexArrays(1, &vao)
	defer gl.DeleteBuffers(1, &vbo)

	prev_wireframe := state.wireframe

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()

		// Apply wireframe toggle (changed inside the key callback).
		if state.wireframe != prev_wireframe {
			gl.PolygonMode(gl.FRONT_AND_BACK, gl.LINE if state.wireframe else gl.FILL)
			prev_wireframe = state.wireframe
		}

		t := f32(glfw.GetTime())

		// Animated time-based clear colour.
		gl.Viewport(0, 0, state.fb_width, state.fb_height)
		gl.ClearColor(
			0.10 + 0.10 * sinf(t * 0.7),
			0.12 + 0.10 * sinf(t * 1.1 + 2.0),
			0.18 + 0.10 * sinf(t * 1.7 + 4.0),
			1.0,
		)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		// Rotation speed tracks cursor X across the window.
		speed := 0.5 + 3.0 * f32(state.cursor_x) / f32(max(state.fb_width, 1))
		gl.UseProgram(program)
		gl.Uniform1f(u_angle, t * speed)
		gl.BindVertexArray(vao)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)

		glfw.SwapBuffers(window)
	}

	fmt.println("Bye.")
}

// --- GLFW callbacks ------------------------------------------------------
//
// GLFW invokes these with the C calling convention and no Odin context, so each
// installs the default context before touching core:fmt.

error_callback :: proc "c" (code: i32, description: cstring) {
	context = runtime.default_context()
	fmt.eprintfln("[glfw error] (%d): %s", code, description)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = runtime.default_context()
	state := (^State)(glfw.GetWindowUserPointer(window))
	if action == glfw.PRESS {
		switch key {
		case glfw.KEY_ESCAPE:
			glfw.SetWindowShouldClose(window, true)
		case glfw.KEY_SPACE, glfw.KEY_W:
			if state != nil {
				state.wireframe = !state.wireframe
			}
		}
	}
	action_name := "press" if action == glfw.PRESS else ("release" if action == glfw.RELEASE else "repeat")
	fmt.printfln("[event] key %s: key=%d scancode=%d mods=0x%x", action_name, key, scancode, mods)
}

mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
	context = runtime.default_context()
	action_name := "down" if action == glfw.PRESS else "up"
	fmt.printfln("[event] mouse button %d %s mods=0x%x", button, action_name, mods)
}

cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
	context = runtime.default_context()
	state := (^State)(glfw.GetWindowUserPointer(window))
	if state != nil {
		state.cursor_x = xpos
		state.cursor_y = ypos
	}
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	context = runtime.default_context()
	state := (^State)(glfw.GetWindowUserPointer(window))
	if state != nil {
		state.fb_width  = width
		state.fb_height = height
	}
	fmt.printfln("[event] framebuffer resized to %dx%d", width, height)
}

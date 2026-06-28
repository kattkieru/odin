package sdl3_demo

// Interactive SDL3 window/renderer demo.
//
// Foreign-imports the *DLL import library* vendor:sdl3 (vendor/sdl3/SDL3.lib),
// which resolves against vendor/sdl3/SDL3.dll at runtime. Because
// SDL3.dll carries its own C runtime and pulls its own system dependencies at
// load time, the cross link only needs SDL3.lib plus the Odin runtime libs --
// no static MSVC CRT (libcmt), and no extra system import libs.
//
// The demo opens a single resizable window with an SDL renderer and runs an
// event loop:
//   - SDL_EVENT_QUIT / window close request  -> quit
//   - SDL_EVENT_KEY_DOWN / KEY_UP            -> Esc quits, Space toggles the
//                                               extra static shapes; logged
//   - SDL_EVENT_MOUSE_MOTION / BUTTON_*      -> moves a follower rect; logged
//   - SDL_EVENT_WINDOW_RESIZED / PIXEL_SIZE  -> logged
// Each frame it clears, draws a few primitives (border rect, two crossing
// lines, a static filled rect, and a filled rect that follows the mouse), then
// presents. Key/mouse/window events are printed to the console,
// so behaviour is observable even before anything is drawn.
//
// Audio: an optional sine tone, compiled in only with -define:DEMO_AUDIO=true
// (off by default so the default build/link surface stays minimal). When
// enabled it opens an SDL_AudioStream and feeds a generated 440 Hz tone; a
// failed audio open degrades to a console warning rather than a crash.
//
// Cross-build (Linux host -> Windows .exe):
//
//     odin build tests/cross/vendor/sdl3 -target:windows_amd64
//
// produces a PE32+ *console* executable importing SDL3.dll via SDL3.lib. For
// the manual Windows run, stage the DLL next to the .exe:
//
//     tests/cross/vendor/stage-dlls.sh sdl3 <outdir>
//
// then run sdl3_demo.exe. See README.md.

import "core:fmt"
import sdl "vendor:sdl3"

// Compile-time switch for the optional audio tone (off by default).
DEMO_AUDIO :: #config(DEMO_AUDIO, false)

WINDOW_W :: 800
WINDOW_H :: 600

main :: proc() {
	fmt.println("SDL3 cross-build demo")
	fmt.println("  Controls: Esc = quit, Space = toggle shapes, move/click the mouse.")

	// Audio is initialised separately in audio_start (when enabled) so an audio
	// subsystem failure degrades gracefully instead of aborting SDL_Init.
	if !sdl.Init(sdl.INIT_VIDEO | sdl.INIT_EVENTS) {
		fmt.eprintfln("SDL_Init failed: %s", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window:   ^sdl.Window
	renderer: ^sdl.Renderer
	if !sdl.CreateWindowAndRenderer("Odin x SDL3 (cross-built)", WINDOW_W, WINDOW_H, sdl.WINDOW_RESIZABLE, &window, &renderer) {
		fmt.eprintfln("SDL_CreateWindowAndRenderer failed: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyRenderer(renderer)
	defer sdl.DestroyWindow(window)

	audio := audio_start()
	defer audio_stop(audio)

	// Mutable demo state driven by input.
	mouse_x, mouse_y: f32 = WINDOW_W / 2, WINDOW_H / 2
	show_extra_shapes := true
	dragging := false

	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				fmt.println("[event] quit requested")
				running = false

			case .WINDOW_CLOSE_REQUESTED:
				fmt.println("[event] window close requested")
				running = false

			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
				fmt.printfln("[event] window resized to %dx%d", event.window.data1, event.window.data2)

			case .KEY_DOWN:
				if !event.key.repeat {
					fmt.printfln("[event] key down: key=0x%x scancode=%v", u32(event.key.key), event.key.scancode)
				}
				switch u32(event.key.key) {
				case sdl.K_ESCAPE:
					fmt.println("  -> Esc pressed, quitting")
					running = false
				case sdl.K_SPACE:
					show_extra_shapes = !show_extra_shapes
					fmt.printfln("  -> shapes toggled %v", "on" if show_extra_shapes else "off")
				}

			case .KEY_UP:
				fmt.printfln("[event] key up: key=0x%x", u32(event.key.key))

			case .MOUSE_MOTION:
				mouse_x = event.motion.x
				mouse_y = event.motion.y
				if dragging {
					fmt.printfln("[event] mouse drag: (%.0f, %.0f)", mouse_x, mouse_y)
				}

			case .MOUSE_BUTTON_DOWN:
				dragging = true
				fmt.printfln("[event] mouse button %d down at (%.0f, %.0f), clicks=%d",
					event.button.button, event.button.x, event.button.y, event.button.clicks)

			case .MOUSE_BUTTON_UP:
				dragging = false
				fmt.printfln("[event] mouse button %d up at (%.0f, %.0f)",
					event.button.button, event.button.x, event.button.y)
			}
		}

		draw_frame(renderer, mouse_x, mouse_y, show_extra_shapes)

		// ~60 FPS cap; SDL renderers default to vsync off.
		sdl.Delay(16)
	}

	fmt.println("Bye.")
}

// Draw one frame: clear, draw primitives, present.
draw_frame :: proc(renderer: ^sdl.Renderer, mouse_x, mouse_y: f32, show_extra_shapes: bool) {
	out_w, out_h: i32
	sdl.GetRenderOutputSize(renderer, &out_w, &out_h)
	w := f32(out_w)
	h := f32(out_h)

	// Dark background.
	sdl.SetRenderDrawColor(renderer, 0x10, 0x12, 0x18, 0xFF)
	sdl.RenderClear(renderer)

	// Outer border rect.
	sdl.SetRenderDrawColor(renderer, 0x40, 0x80, 0xFF, 0xFF)
	border := sdl.FRect{4, 4, w - 8, h - 8}
	sdl.RenderRect(renderer, &border)

	// Two crossing diagonal lines.
	sdl.SetRenderDrawColor(renderer, 0x30, 0x40, 0x60, 0xFF)
	sdl.RenderLine(renderer, 0, 0, w, h)
	sdl.RenderLine(renderer, w, 0, 0, h)

	if show_extra_shapes {
		// Static filled rect near the centre.
		sdl.SetRenderDrawColor(renderer, 0xC0, 0x60, 0x30, 0xFF)
		static_rect := sdl.FRect{w / 2 - 60, h / 2 - 40, 120, 80}
		sdl.RenderFillRect(renderer, &static_rect)
	}

	// Filled rect that follows the mouse.
	sdl.SetRenderDrawColor(renderer, 0x40, 0xD0, 0x60, 0xFF)
	follower := sdl.FRect{mouse_x - 15, mouse_y - 15, 30, 30}
	sdl.RenderFillRect(renderer, &follower)

	sdl.RenderPresent(renderer)
}

// ---------------------------------------------------------------------------
// Optional audio tone (compiled in only with -define:DEMO_AUDIO=true).
// ---------------------------------------------------------------------------

when DEMO_AUDIO {
	TONE_HZ   :: 440.0
	TONE_FREQ :: 48000 // sample rate
	TWO_PI    :: f32(2 * 3.14159265358979323846)

	// The sine generator needs libc's sinf. SDL3.lib alone does not pull a CRT
	// (SDL3.dll carries its own), so on the Windows cross path name ucrtbase
	// ourselves and keep sinf live -- the same pattern the cgltf demo uses for
	// its libc surface. ucrtbase.dll exports sinf; on other targets sinf comes
	// from the platform libc (linked automatically).
	when ODIN_OS == .Windows {
		foreign import ucrt "system:ucrtbase.lib"
		@(default_calling_convention="c")
		foreign ucrt {
			sinf :: proc(x: f32) -> f32 ---
		}
	} else {
		foreign import libm "system:m"
		@(default_calling_convention="c")
		foreign libm {
			sinf :: proc(x: f32) -> f32 ---
		}
	}

	Audio_State :: struct {
		stream: ^sdl.AudioStream,
		phase:  f32,
	}

	@(private)
	g_audio: Audio_State

	audio_start :: proc() -> ^Audio_State {
		// Bring up the audio subsystem on its own so a failure here is isolated.
		if !sdl.InitSubSystem(sdl.INIT_AUDIO) {
			fmt.eprintfln("[audio] could not init audio subsystem (%s); continuing without sound", sdl.GetError())
			return nil
		}
		spec := sdl.AudioSpec{
			format   = .F32,
			channels = 1,
			freq     = TONE_FREQ,
		}
		stream := sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, audio_callback, &g_audio)
		if stream == nil {
			// Degrade gracefully: no tone, but the demo keeps running.
			fmt.eprintfln("[audio] could not open audio device (%s); continuing without sound", sdl.GetError())
			return nil
		}
		g_audio.stream = stream
		sdl.ResumeAudioStreamDevice(stream)
		fmt.println("[audio] 440 Hz sine tone enabled")
		return &g_audio
	}

	audio_stop :: proc(state: ^Audio_State) {
		if state != nil && state.stream != nil {
			sdl.DestroyAudioStream(state.stream)
			state.stream = nil
		}
	}

	// SDL pulls audio via this callback; generate the requested number of
	// float samples on the fly.
	audio_callback :: proc "c" (userdata: rawptr, stream: ^sdl.AudioStream, additional_amount, total_amount: i32) {
		if additional_amount <= 0 {
			return
		}
		state := (^Audio_State)(userdata)
		sample_count := int(additional_amount) / size_of(f32)
		step := f32(TWO_PI * TONE_HZ / TONE_FREQ)

		buf: [512]f32
		for sample_count > 0 {
			n := min(sample_count, len(buf))
			for i in 0 ..< n {
				buf[i] = 0.15 * sinf(state.phase)
				state.phase += step
				if state.phase > TWO_PI {
					state.phase -= TWO_PI
				}
			}
			sdl.PutAudioStreamData(stream, &buf[0], i32(n * size_of(f32)))
			sample_count -= n
		}
	}
} else {
	// Audio disabled: no-op stand-ins so the call sites stay uniform.
	Audio_State :: struct {}

	audio_start :: proc() -> ^Audio_State {
		return nil
	}

	audio_stop :: proc(state: ^Audio_State) {
	}
}

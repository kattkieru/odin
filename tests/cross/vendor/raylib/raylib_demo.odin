package raylib_demo

// Interactive raylib playground.
//
// Foreign-imports vendor:raylib built with -define:RAYLIB_SHARED=true, which
// selects the DLL import library vendor/raylib/windows/raylibdll.lib (-> the
// runtime raylib.dll) instead of the static raylib.lib default,
// and flips the binding's /NODEFAULTLIB from libcmt to msvcrt. The shared
// raylib Windows binding also references system:Winmm.lib + system:Gdi32.lib +
// system:User32.lib + system:Shell32.lib, all provided by the bundled
// import libs. (raylib.dll resolves those system DLLs itself at runtime, so they
// do not necessarily appear in this exe's import table -- raylib.dll does.)
//
// The demo is a windowed playground:
//   - opens an 800x600 window, target 60 FPS,
//   - keyboard input: arrow keys / WASD move a player rectangle, Space plays a
//     sound, R resets, Esc / window-close ends the loop,
//   - mouse input: left button drags/paints colored dots, position is tracked,
//   - draws 2D shapes (rectangles, circles, lines), text, and a small bundled
//     texture (assets/icon.png), and follows the mouse with a circle,
//   - plays a small bundled sound (assets/blip.wav) on Space / on mouse paint,
//     degrading to a console note if the audio device fails,
//   - draws an on-screen FPS counter via DrawFPS.
//
// Assets are loaded at runtime from disk (assets/icon.png + assets/blip.wav),
// so for the manual Windows run the assets/ folder must sit next to the .exe
// alongside raylib.dll. See README.md.
//
// Cross-build (Linux host -> Windows .exe):
//
//     odin build tests/cross/vendor/raylib -out:raylib_demo.exe \
//         -target:windows_amd64 -define:RAYLIB_SHARED=true
//
// produces a PE32+ *console* executable importing raylib.dll (via raylibdll.lib).
// For the manual Windows run, stage the DLL next to the .exe:
//
//     tests/cross/vendor/stage-dlls.sh raylib <outdir>
//
// then copy the assets/ folder next to raylib_demo.exe and run it.

import "core:fmt"
import rl "vendor:raylib"

WIDTH  :: 800
HEIGHT :: 600

MAX_DOTS :: 256

Dot :: struct {
	pos:   rl.Vector2,
	color: rl.Color,
}

main :: proc() {
	rl.InitWindow(WIDTH, HEIGHT, "Odin cross raylib playground")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	// Audio is optional: a failed device init degrades to a console note rather
	// than crashing.
	rl.InitAudioDevice()
	audio_ok := rl.IsAudioDeviceReady()
	if !audio_ok {
		fmt.println("[raylib_demo] audio device not ready -- continuing without sound")
	}
	defer if audio_ok do rl.CloseAudioDevice()

	sound: rl.Sound
	sound_ok := false
	if audio_ok {
		sound = rl.LoadSound("assets/blip.wav")
		sound_ok = rl.IsSoundValid(sound)
		if !sound_ok {
			fmt.println("[raylib_demo] could not load assets/blip.wav -- no sound")
		}
	}
	defer if sound_ok do rl.UnloadSound(sound)

	// Small bundled texture; degrade gracefully if missing.
	texture := rl.LoadTexture("assets/icon.png")
	texture_ok := rl.IsTextureValid(texture)
	if !texture_ok {
		fmt.println("[raylib_demo] could not load assets/icon.png -- drawing a placeholder")
	}
	defer if texture_ok do rl.UnloadTexture(texture)

	play_blip :: proc(sound: rl.Sound, ok: bool) {
		if ok do rl.PlaySound(sound)
	}

	// Player rectangle driven by keyboard.
	player := rl.Vector2{WIDTH / 2 - 20, HEIGHT / 2 - 20}
	start := player
	speed: f32 = 240 // pixels / second

	// Mouse-painted dots.
	dots: [MAX_DOTS]Dot
	dot_count := 0

	frame := 0

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		frame += 1

		// --- keyboard input ---
		if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) do player.x += speed * dt
		if rl.IsKeyDown(.LEFT)  || rl.IsKeyDown(.A) do player.x -= speed * dt
		if rl.IsKeyDown(.DOWN)  || rl.IsKeyDown(.S) do player.y += speed * dt
		if rl.IsKeyDown(.UP)    || rl.IsKeyDown(.W) do player.y -= speed * dt

		// clamp inside the window
		if player.x < 0          do player.x = 0
		if player.x > WIDTH - 40  do player.x = WIDTH - 40
		if player.y < 0          do player.y = 0
		if player.y > HEIGHT - 40 do player.y = HEIGHT - 40

		if rl.IsKeyPressed(.SPACE) {
			play_blip(sound, sound_ok)
		}
		if rl.IsKeyPressed(.R) {
			player = start
			dot_count = 0
		}

		// --- mouse input ---
		mouse := rl.GetMousePosition()
		if rl.IsMouseButtonDown(.LEFT) {
			if dot_count < MAX_DOTS {
				palette := [?]rl.Color{rl.RED, rl.GREEN, rl.BLUE, rl.GOLD, rl.MAROON}
				dots[dot_count] = Dot{mouse, palette[dot_count % len(palette)]}
				dot_count += 1
			}
		}
		if rl.IsMouseButtonPressed(.RIGHT) {
			play_blip(sound, sound_ok)
		}

		// --- draw ---
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{30, 30, 46, 255})

		// 2D shapes: framed canvas + crossing guide lines.
		rl.DrawRectangleLines(8, 8, WIDTH - 16, HEIGHT - 16, rl.DARKGRAY)
		rl.DrawLine(0, HEIGHT / 2, WIDTH, HEIGHT / 2, rl.Color{60, 60, 80, 255})
		rl.DrawLine(WIDTH / 2, 0, WIDTH / 2, HEIGHT, rl.Color{60, 60, 80, 255})

		// painted dots
		for i in 0 ..< dot_count {
			rl.DrawCircleV(dots[i].pos, 6, dots[i].color)
		}

		// player rectangle
		rl.DrawRectangleV(player, rl.Vector2{40, 40}, rl.GOLD)
		rl.DrawRectangleLines(i32(player.x), i32(player.y), 40, 40, rl.WHITE)

		// circle that follows the mouse
		rl.DrawCircleLinesV(mouse, 14, rl.GREEN)

		// bundled texture (or a placeholder rectangle if it failed to load)
		if texture_ok {
			rl.DrawTexture(texture, WIDTH - texture.width - 24, 24, rl.WHITE)
		} else {
			rl.DrawRectangle(WIDTH - 88, 24, 64, 64, rl.MAROON)
		}

		// text + HUD
		rl.DrawText("Odin cross-compiled raylib playground", 24, 24, 20, rl.RAYWHITE)
		rl.DrawText("Move: WASD / arrows   Paint: left mouse   Sound: Space / right mouse   Reset: R   Quit: Esc",
			24, 52, 10, rl.LIGHTGRAY)
		hud := rl.TextFormat("player=(%.0f, %.0f)  mouse=(%.0f, %.0f)  dots=%d  audio=%s",
			player.x, player.y, mouse.x, mouse.y, dot_count, "on" if sound_ok else "off")
		rl.DrawText(hud, 24, HEIGHT - 28, 10, rl.LIGHTGRAY)

		// on-screen FPS
		rl.DrawFPS(WIDTH - 92, HEIGHT - 28)

		rl.EndDrawing()
	}

	fmt.println("[raylib_demo] window closed cleanly after", frame, "frames")
}

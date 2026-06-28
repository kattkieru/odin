package box2d_demo

// Interactive physics-sandbox demo.
//
// Combines the *static* vendor:box2d MSVC library with shared vendor:raylib for
// rendering and input, in a single Windows cross-link:
//
//   - box2d is a static .lib (lib/box2d_windows_amd64_{avx2,sse2}.lib). Built
//     with -define:VENDOR_BOX2D_ENABLE_AVX2=false it selects the *sse2* variant
//     (the safe baseline for the manual test's unknown Windows CPU; the avx2
//     variant links fine too on an avx2-capable target). It is linked into the
//     .exe, so box2d does NOT appear in the import table.
//   - raylib is the shared variant (-define:RAYLIB_SHARED=true), selecting
//     vendor/raylib/windows/raylibdll.lib -> the runtime raylib.dll,
//     and flipping the binding's /NODEFAULTLIB from libcmt to msvcrt.
//     raylib.dll DOES appear in the import table; it must be staged next to the
//     .exe for the manual run.
//
// Because the box2d MSVC static lib is CRT-light it references the
// ucrt libc (malloc/free/...) plus a handful of static-CRT-internal symbols
// (__security_cookie, __GSHandlerCheck, ...). The latter are provided by the
// bundled compiler-rt CRT-support stubs. The former (ucrtbase) is
// only put on the link line when an Odin package keeps a *live* reference to it
// (unreferenced system: imports are pruned), so this
// demo declares `foreign import "system:ucrtbase.lib"` and uses malloc/free as
// box2d's allocator callbacks to keep it live (see set_box2d_allocator below).
//
// The sandbox itself:
//   - a b2World with downward gravity, a static ground + two side walls,
//   - LEFT click spawns a dynamic box or circle (toggle with TAB) at the cursor;
//     bodies fall, stack and collide,
//   - LEFT click+drag on an existing body grabs and moves it (overlap query +
//     per-frame velocity steering), release to drop,
//   - RIGHT click / C / R clears all dynamic bodies,
//   - fixed-timestep b2World_Step per frame; every body rendered with raylib
//     using its box2d transform; on-screen help text + DrawFPS.
//
// Cross-build (Linux host -> Windows .exe):
//
//     odin build tests/cross/vendor/box2d -out:box2d_demo.exe \
//         -target:windows_amd64 -define:RAYLIB_SHARED=true \
//         -define:VENDOR_BOX2D_ENABLE_AVX2=false
//
// produces a PE32+ *console* executable importing raylib.dll (+ ucrtbase.dll)
// with box2d statically linked in. For the manual Windows run, stage raylib.dll
// next to the .exe:
//
//     tests/cross/vendor/stage-dlls.sh box2d <outdir>
//
// then run box2d_demo.exe. See README.md.

import "core:fmt"
import b2 "vendor:box2d"
import rl "vendor:raylib"

// set_box2d_allocator keeps ucrtbase live on the Windows link line by routing
// box2d's allocator through ucrt malloc/free. It is defined per-OS:
//   - box2d_demo_windows.odin: foreign-imports system:ucrtbase.lib + sets it,
//   - box2d_demo_other.odin:   a no-op (platform libc links automatically).
// (foreign import / import cannot live inside a `when`, hence the file split.)

WIDTH :: 900
HEIGHT :: 640

// Pixels per box2d meter. box2d works best in meters, so render-space pixels are
// converted on the way in/out.
PPM :: 48.0

MAX_BODIES :: 512

// box2d uses a y-up world; the screen is y-down. World origin sits at the bottom
// of the window so gravity pulls things toward the visible floor.
to_world :: proc(p: rl.Vector2) -> b2.Vec2 {
	return b2.Vec2{p.x / PPM, (f32(HEIGHT) - p.y) / PPM}
}
to_screen :: proc(p: b2.Vec2) -> rl.Vector2 {
	return rl.Vector2{p.x * PPM, f32(HEIGHT) - p.y * PPM}
}

Shape_Kind :: enum {
	Box,
	Circle,
}

Entity :: struct {
	id:    b2.BodyId,
	kind:  Shape_Kind,
	// Half-extents (box) or radius (circle), in meters.
	hx:    f32,
	hy:    f32,
	r:     f32,
	color: rl.Color,
}

// Context passed to the overlap query when grabbing a body under the cursor.
Grab_Query :: struct {
	found: b2.BodyId,
	got:   bool,
}

overlap_cb :: proc "c" (shapeId: b2.ShapeId, ctx: rawptr) -> bool {
	q := (^Grab_Query)(ctx)
	body := b2.Shape_GetBody(shapeId)
	if b2.Body_GetType(body) == .dynamicBody {
		q.found = body
		q.got = true
		return false // stop the query, we have one
	}
	return true // keep searching
}

PALETTE := [?]rl.Color {
	rl.RED,
	rl.GREEN,
	rl.SKYBLUE,
	rl.GOLD,
	rl.VIOLET,
	rl.ORANGE,
	rl.LIME,
	rl.PINK,
}

main :: proc() {
	set_box2d_allocator()

	world_def := b2.DefaultWorldDef()
	world_def.gravity = b2.Vec2{0, -10}
	world := b2.CreateWorld(world_def)
	defer b2.DestroyWorld(world)

	bodies := make([dynamic]Entity, 0, MAX_BODIES)
	defer delete(bodies)

	// --- static ground + side walls ---
	make_static_box :: proc(world: b2.WorldId, cx, cy, hx, hy: f32) {
		bd := b2.DefaultBodyDef()
		bd.type = .staticBody
		bd.position = b2.Vec2{cx, cy}
		body := b2.CreateBody(world, bd)
		sd := b2.DefaultShapeDef()
		poly := b2.MakeBox(hx, hy)
		_ = b2.CreatePolygonShape(body, sd, poly)
	}

	ground_h: f32 = 0.5
	wall_w: f32 = 0.5
	w_m := f32(WIDTH) / PPM
	h_m := f32(HEIGHT) / PPM
	make_static_box(world, w_m / 2, ground_h, w_m / 2, ground_h) // floor
	make_static_box(world, wall_w, h_m / 2, wall_w, h_m / 2) // left wall
	make_static_box(world, w_m - wall_w, h_m / 2, wall_w, h_m / 2) // right wall

	spawn_body :: proc(world: b2.WorldId, bodies: ^[dynamic]Entity, at: b2.Vec2, kind: Shape_Kind, color: rl.Color) -> bool {
		if len(bodies) >= MAX_BODIES do return false
		bd := b2.DefaultBodyDef()
		bd.type = .dynamicBody
		bd.position = at
		body := b2.CreateBody(world, bd)

		sd := b2.DefaultShapeDef()
		sd.density = 1.0
		sd.material.friction = 0.4
		sd.material.restitution = 0.15

		e := Entity {
			id    = body,
			kind  = kind,
			color = color,
		}
		switch kind {
		case .Box:
			e.hx = 0.35
			e.hy = 0.35
			poly := b2.MakeBox(e.hx, e.hy)
			_ = b2.CreatePolygonShape(body, sd, poly)
		case .Circle:
			e.r = 0.38
			circle := b2.Circle{center = b2.Vec2{0, 0}, radius = e.r}
			_ = b2.CreateCircleShape(body, sd, circle)
		}
		append(bodies, e)
		return true
	}

	clear_bodies :: proc(bodies: ^[dynamic]Entity) {
		for e in bodies {
			if b2.Body_IsValid(e.id) {
				b2.DestroyBody(e.id)
			}
		}
		clear(bodies)
	}

	rl.InitWindow(WIDTH, HEIGHT, "Odin cross box2d physics sandbox")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	next_kind := Shape_Kind.Box
	color_idx := 0

	// Drag state.
	grabbing := false
	grabbed: b2.BodyId

	TIME_STEP: f32 = 1.0 / 60.0
	SUB_STEPS :: 4

	spawned := 0

	for !rl.WindowShouldClose() {
		mouse := rl.GetMousePosition()
		mworld := to_world(mouse)

		// --- input: toggle spawn shape ---
		if rl.IsKeyPressed(.TAB) {
			next_kind = .Circle if next_kind == .Box else .Box
		}

		// --- input: clear ---
		if rl.IsKeyPressed(.C) || rl.IsKeyPressed(.R) || rl.IsMouseButtonPressed(.RIGHT) {
			clear_bodies(&bodies)
			grabbing = false
			spawned = 0
		}

		// --- input: left-press -> grab existing body, else spawn a new one ---
		if rl.IsMouseButtonPressed(.LEFT) {
			q: Grab_Query
			d: f32 = 0.001
			aabb := b2.AABB {
				lowerBound = b2.Vec2{mworld.x - d, mworld.y - d},
				upperBound = b2.Vec2{mworld.x + d, mworld.y + d},
			}
			_ = b2.World_OverlapAABB(world, aabb, b2.DefaultQueryFilter(), overlap_cb, &q)
			if q.got {
				grabbing = true
				grabbed = q.found
				b2.Body_SetAwake(grabbed, true)
			} else {
				if spawn_body(world, &bodies, mworld, next_kind, PALETTE[color_idx % len(PALETTE)]) {
					color_idx += 1
					spawned += 1
				}
			}
		}

		// --- drag: steer the grabbed body toward the cursor ---
		if grabbing {
			if rl.IsMouseButtonDown(.LEFT) && b2.Body_IsValid(grabbed) {
				pos := b2.Body_GetPosition(grabbed)
				// Velocity that closes the gap in one step (kinematic-feeling drag).
				vel := b2.Vec2{(mworld.x - pos.x) / TIME_STEP, (mworld.y - pos.y) / TIME_STEP}
				b2.Body_SetLinearVelocity(grabbed, vel)
				b2.Body_SetAwake(grabbed, true)
			} else {
				grabbing = false
			}
		}

		// --- step physics (fixed timestep) ---
		b2.World_Step(world, TIME_STEP, SUB_STEPS)

		// --- draw ---
		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{24, 24, 36, 255})

		// floor + walls (drawn from their known geometry)
		rl.DrawRectangle(0, HEIGHT - i32(2 * ground_h * PPM), WIDTH, i32(2 * ground_h * PPM), rl.Color{60, 60, 80, 255})
		rl.DrawRectangle(0, 0, i32(2 * wall_w * PPM), HEIGHT, rl.Color{60, 60, 80, 255})
		rl.DrawRectangle(WIDTH - i32(2 * wall_w * PPM), 0, i32(2 * wall_w * PPM), HEIGHT, rl.Color{60, 60, 80, 255})

		// dynamic bodies
		for e in bodies {
			if !b2.Body_IsValid(e.id) do continue
			xf := b2.Body_GetTransform(e.id)
			center := to_screen(xf.p)
			switch e.kind {
			case .Box:
				// box2d's Rot is (cos, sin); recover the angle and convert to
				// degrees. World is CCW + y-up, raylib screen rotation is CW +
				// y-down, so negate to match the on-screen orientation.
				angle_deg := atan2_f32(xf.q.s, xf.q.c) * rl.RAD2DEG
				rect := rl.Rectangle {
					x      = center.x,
					y      = center.y,
					width  = e.hx * 2 * PPM,
					height = e.hy * 2 * PPM,
				}
				origin := rl.Vector2{e.hx * PPM, e.hy * PPM}
				rl.DrawRectanglePro(rect, origin, -angle_deg, e.color)
			case .Circle:
				rl.DrawCircleV(center, e.r * PPM, e.color)
				rl.DrawCircleLinesV(center, e.r * PPM, rl.Fade(rl.WHITE, 0.4))
			}
		}

		// cursor preview of the next shape
		preview := rl.Fade(PALETTE[color_idx % len(PALETTE)], 0.35)
		if next_kind == .Box {
			rl.DrawRectanglePro(rl.Rectangle{mouse.x, mouse.y, 0.35 * 2 * PPM, 0.35 * 2 * PPM}, rl.Vector2{0.35 * PPM, 0.35 * PPM}, 0, preview)
		} else {
			rl.DrawCircleV(mouse, 0.38 * PPM, preview)
		}

		// help text + HUD
		rl.DrawText("Odin cross-compiled box2d physics sandbox", 20, 16, 20, rl.RAYWHITE)
		rl.DrawText(
			"Left click: spawn / grab+drag    TAB: toggle box/circle    Right click / C / R: clear    Esc: quit",
			20,
			44,
			10,
			rl.LIGHTGRAY,
		)
		hud := rl.TextFormat(
			"shape=%s  bodies=%d  spawned=%d  dragging=%s",
			"box" if next_kind == .Box else "circle",
			i32(len(bodies)),
			i32(spawned),
			"yes" if grabbing else "no",
		)
		rl.DrawText(hud, 20, HEIGHT - 26, 10, rl.LIGHTGRAY)
		rl.DrawFPS(WIDTH - 92, HEIGHT - 26)

		rl.EndDrawing()
	}

	clear_bodies(&bodies)
	fmt.println("[box2d_demo] window closed cleanly; total bodies spawned:", spawned)
}

// Self-contained atan2 (radians) so the demo pulls in no libm / core:math trig
// (sibling demos hit `lld-link: undefined symbol: sinf` when they used
// core:math). box2d's Rot is unit-length (cos, sin); a cheap rational
// approximation (max error ~0.01 rad) is plenty for rendering box rotation.
atan2_f32 :: proc(y, x: f32) -> f32 {
	PI :: 3.14159265358979323846
	HALF_PI :: PI / 2
	if x == 0 {
		if y > 0 do return HALF_PI
		if y < 0 do return -HALF_PI
		return 0
	}
	atan_approx :: proc(z: f32) -> f32 {
		// |z| <= 1 ; rational minimax-ish approximation of atan.
		return z / (1 + 0.28 * z * z)
	}
	z := y / x
	if abs(z) < 1 {
		a := atan_approx(z)
		if x < 0 {
			return a + (PI if y >= 0 else -PI)
		}
		return a
	} else {
		a := HALF_PI - atan_approx(1 / z)
		if y < 0 do return a - PI
		return a
	}
}

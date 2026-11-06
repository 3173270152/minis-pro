# Qihang (Godot 4.4.1, GDScript, Forward+) — workstream contract

Project root: `/tmp/claude-0/-home-user-minis-pro/13675e20-5bb0-5214-96c6-047f001eab07/scratchpad/qg`
Godot binary: `/tmp/claude-0/-home-user-minis-pro/13675e20-5bb0-5214-96c6-047f001eab07/scratchpad/godot/Godot_v4.4.1-stable_linux.x86_64`
Target: iPhone (Metal, Forward+, 120 Hz ProMotion). All content is built in code (no editor). Chinese UI text everywhere.

## Rules
- Only edit the files your workstream owns (listed in your brief). `main.gd` is owned by the integrator: if you need a hook
  there, write it inside your own module (use `game.<field>`) or describe the needed hook in your final report.
- New `class_name` scripts: run `$G --headless --path . --import` once so the class cache knows them.
- GDScript gotchas: `:=` cannot infer from Variant (use `var x: float = ...`), use `maxf/minf/clampf/lerpf/absf`,
  `look_at*` uses GLOBAL coords (use `U.aim(node, local_pos, local_target, up)` for parent-local aiming), Godot front faces
  are clockwise; `U.lathe(prof, seg, phi0, phi1, flip)` gives outward normals (flip=true for interiors).
- Performance matters (iPhone, 120 fps target): prefer MultiMeshInstance3D / one mesh per material over hundreds of
  MeshInstance3D; share materials; avoid per-frame allocations; no extra shadowed lights unless essential.
- Check compile: `$G --headless --path . --import 2>&1 | grep -E "SCRIPT ERROR|at: GD"`
- Screenshot (CPU lavapipe, slow ~40-90 s, 4 cores shared with other workers — keep renders few):
  `./shot.sh <view> /path/out.png [--user-args]` views: pad wide base top tower capx chase cabin cabin:<yaw>:<pitch>
  extra args: `--powered` (console configured), `--flight=<sec after liftoff>`, `--T=<countdown>`.
  You may add your own `--view=` handling inside your module's setup (read `OS.get_cmdline_user_args()`).

## Frames
- `game.site` (Node3D) holds World (terrain/sky), Pad, Earth. Floating origin: during flight the rocket sits near (0, Pad.DECK, 0)
  and `site.position` moves. Earth centre in site frame = (0, -Earth.R, 0). Downrange = +X. Tower at -X.
- Capsule frame (Capsule): origin = heat-shield floor centre, +Y up the rocket axis; crew lie on backs, heads toward +X,
  seats across Z (-0.62, 0, +0.62), player = centre seat; `capsule.seat_anchor` is the eye; `capsule.surfaces()` gives
  console mounting surfaces consumed by `Console.flow()`.

## Game object (main.gd) fields modules may read/write
site, world (World: env, sun, sky_mat, terrain), pad (Pad: DECK, TOWER_X, arm_y, elevator, arm, white_room), earth (Earth: set_fade, place),
rocket (Rocket: kind, stage1, stage2, boosters, fairing, les, plume_points, y_cap, cap_mount, events), capsule, console (Console),
hud (Hud: say(who,text,dur), objective.text, clock, phase_l, tele, proc_box, button signal), sfx (Sfx: line(id, delay, now), click(), set_engine()),
cam (Camera3D), cam_mode ("seat"/"chase"/"fixed"/"module" — set "module" to drive the camera yourself),
T (mission clock s), lifted, stage, alt, vel, gload, phase (String) + set_phase(p) + signal phase_changed, cfg (rocket/mode/dis/skip_walk),
yaw/pitch/zoom (look input), _later(sec, callable), _detach(node, vel).
Phases: "crew" (walking, before seated) -> "seat" -> "ascent" -> "orbit" -> "rdv" -> "docked" -> "eva" -> "deorbit" -> "entry" -> "landed"; "abort"; "spectator".
main.gd drives "seat" countdown and "ascent" flight only; every other phase is module-driven (set cam_mode = "module").

## Module contract
A module file listed in `main.MODULE_FILES` is instantiated after loading: `var m = load(f).new()`; if it is a Node it is
added as child; then `m.setup(game)`; every frame `m.tick(dt)` (only after loading is done).
Voice line ids available: see `scripts/lines.gd` (`Lines.L`), audio at `res://audio/<id>.mp3`.

extends Node3D
## Qihang: first-person crewed launch. Builds the site, rocket, capsule and console, then runs the mission:
## seated pre-launch configuration -> launch poll -> terminal count -> ignition -> ascent & staging -> orbit.
## Floating origin: the rocket stays near (0,0,0); the whole site (terrain, pad, Earth) moves underneath it.

var site: Node3D
var world: World
var pad: Pad
var earth: Earth
var rocket: Rocket
var capsule: Capsule
var console: Console
var hud: Hud
var sfx: Sfx
var cam: Camera3D

# mission state
var T := -60.0
var running := false
var poll_done := false
var wait_go := false
var crew_go := false
var lifted := false
var held := ""
var ev_i := 0
var ph := 0
var guide := false
var crew_exec := false
var guide_step: Array = []
var crew_timer := 0.0
var cam_mode := "seat"
var yaw := 0.0
var pitch := 0.0
var zoom := 1.0
var cdist := 75.0   # external camera distance from the rocket axis (pinch / wheel)
var shake := 0.0
var traj: Array = []        # [t, h, x, v, pitch]
var alt := 0.0
var vel := 0.0
var gload := 1.0
var qdyn := 0.0
var detached: Array = []    # [node, velocity, spin]
var plumes: Array = []
var smoke: GPUParticles3D
var stage := 0              # 0 core+boosters, 1 core, 2 second stage, 3 orbit
var throttle := 0.0
var tip_id := ""
var drag_from := Vector2.ZERO
var dragging := false
var moved := 0.0
var touches := {}
var pinch0 := 0.0
var shot := ""
var view := ""
var frames := 0
var cfg := {"rocket": "qihang", "mode": "astronaut", "dis": "off", "skip_walk": false}
var phase := "seat"          # crew / seat / ascent / orbit / rdv / docked / eva / deorbit / entry / landed / abort / spectator
var spec_track := true
var modules: Array = []       # feature modules: each has setup(game) and tick(dt); see scripts/README_modules.md
signal phase_changed(p: String)
## feature modules loaded if present (each file owned by one workstream)
const MODULE_FILES := ["res://scripts/vfx.gd", "res://scripts/engine_audio.gd", "res://scripts/mfd.gd", "res://scripts/crewday.gd", "res://scripts/orbit.gd", "res://scripts/entry.gd", "res://scripts/spectator.gd", "res://scripts/clouds.gd", "res://scripts/disaster.gd"]

func set_phase(p: String) -> void:
	if phase == p: return
	phase = p; print("[phase] ", p); phase_changed.emit(p)

func _load_modules() -> void:
	for f in MODULE_FILES:
		if ResourceLoader.exists(f):
			var sc = load(f)
			if sc == null or not sc.can_instantiate(): push_error("module failed to load: " + f); continue
			var m = sc.new()
			if m is Node: add_child(m)
			modules.append(m)
			if m.has_method("setup"): m.setup(self)

const VIEWS := {
	"pad": [Vector3(48, 10, 95), Vector3(-4, 34, 0)], "wide": [Vector3(260, 30, 330), Vector3(0, 40, 0)],
	"base": [Vector3(14, 4.0, 18), Vector3(0, 12, 0)], "top": [Vector3(9, 62, 13), Vector3(0, 59, 0)],
	"tower": [Vector3(30, 50, -30), Vector3(-13, 45, 0)], "hiview": [Vector3(30, Pad.DECK + 8, 30), Vector3(0, Pad.DECK - 250, 1500)], "plumex": [Vector3(45, Pad.DECK + 5, 45), Vector3(0, Pad.DECK - 25, 0)], "capx": [Vector3(5, 58, 5), Vector3(0, 56.5, 0)],
}

var loading: CanvasLayer
var load_label: Label
var ready_done := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="): shot = a.substr(7)
		if a.begins_with("--view="): view = a.substr(7)
	# loading screen first so the device leaves the splash immediately; the heavy build runs over the next frames
	var debug := shot != "" or view != ""
	for a in OS.get_cmdline_user_args(): if a.begins_with("--flight=") or a.begins_with("--T=") or a == "--nomenu": debug = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rocket="): cfg.rocket = a.substr(9)
		if a.begins_with("--mode="): cfg.mode = a.substr(7)
		if a.begins_with("--dis="): cfg.dis = a.substr(6)
	if not debug:
		var menu := Menu.new(); add_child(menu)
		var c: Dictionary = await menu.start
		for k in c: cfg[k] = c[k]
	loading = CanvasLayer.new(); loading.layer = 50; add_child(loading)
	var bg := ColorRect.new(); bg.color = Color(0.02, 0.03, 0.06); bg.set_anchors_preset(Control.PRESET_FULL_RECT); loading.add_child(bg)
	var t := Label.new(); t.text = "启航号"; t.add_theme_font_size_override("font_size", 64); t.set_anchors_preset(Control.PRESET_CENTER); t.position = Vector2(-110, -90); loading.add_child(t)
	load_label = Label.new(); load_label.text = "正在加载…"; load_label.add_theme_font_size_override("font_size", 22); load_label.set_anchors_preset(Control.PRESET_CENTER); load_label.position = Vector2(-160, 10); load_label.size = Vector2(320, 40)
	load_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; loading.add_child(load_label)
	_build.call_deferred()

func _step(msg: String) -> void:
	load_label.text = msg; print("[load] ", msg)
	await get_tree().process_frame
	await get_tree().process_frame

func _build() -> void:
	_quality()
	await _step("正在生成戈壁地形与天空…")
	site = Node3D.new(); site.name = "Site"; add_child(site)
	world = World.new(); site.add_child(world)
	await _step("正在建造发射场与发射塔…")
	rocket = Rocket.new(cfg.rocket)
	pad = Pad.new()
	await _step("正在加载地球（NASA 卫星影像）…")
	earth = Earth.new(); site.add_child(earth)
	var tm: ShaderMaterial = world.terrain.material_override
	tm.set_shader_parameter("day", load("res://tex/earth/2_no_clouds_4k.jpg")); tm.set_shader_parameter("inv_b", Basis(earth.surf.basis).orthonormalized().inverse())
	await _step("正在组装启航号运载火箭…")
	rocket.position = Vector3(0, Pad.DECK, 0); add_child(rocket)
	pad.veh_top = rocket.top; pad.veh_cap = rocket.y_cap; pad.veh_hatch_x = rocket.cap_mount.position.x - rocket.r_hatch
	site.add_child(pad)
	await _step("正在布置返回舱座舱…")
	capsule = Capsule.new(); capsule.variant = rocket.cab; rocket.cap_mount.add_child(capsule)
	await _step("正在安装控制台（约 190 个开关与断路器）…")
	console = Console.new(cfg.rocket if cfg.rocket != "cz2f" else "qihang"); add_child(console)
	var L: Array = console.panel_list(); var sf: Array = capsule.surfaces()
	console.flow([sf[0]], ["abt", "cw", "dok", "avi", "com", "prp", "lts", "seq"].map(func(k): return console.find_panel(L, k)))
	console.flow([sf[1]], ["eps", "cba", "cbc"].map(func(k): return console.find_panel(L, k)))
	console.flow([sf[2]], ["ecs", "cbb"].map(func(k): return console.find_panel(L, k)))
	console.caution.connect(_on_caution)
	if OS.get_cmdline_user_args().has("--fit"): print("[fit] bad corners: ", capsule.check_fit(console))
	await _step("正在准备语音与音效…")
	sfx = Sfx.new(); add_child(sfx); sfx.subtitle.connect(func(w, tx, d): hud.say(w, tx, d))
	hud = Hud.new(); add_child(hud); hud.button.connect(_on_button)
	cam = Camera3D.new(); cam.fov = 74; cam.near = 0.03; cam.far = 2.0e5; add_child(cam); cam.make_current()
	for a in OS.get_cmdline_user_args():
		if a == "--powered": console.auto_upto("int")
		if a.begins_with("--flight="):
			T = 2.0; lifted = true; running = true; poll_done = true; console.auto_upto("int"); phase = "ascent"; ff = true
			var tgt := float(a.substr(9))
			while flight == null or flight.t < tgt: _flight(0.05)
			ff = false
		if a.begins_with("--T="): T = float(a.substr(4)); running = true; poll_done = true; crew_go = true; console.auto_upto("int")
	console.hatch_closed = true
	if cfg.mode == "spectator":
		console.auto_upto("int"); poll_done = true; crew_go = true; running = true; T = -100.0; set_phase("spectator"); hud.proc_box.visible = false
	if view == "chase": cam_mode = "chase"; yaw = 0.6; pitch = 0.1
	elif view != "" and not view.begins_with("cabin"):
		hud.visible = false; var v: Array = VIEWS.get(view, VIEWS["pad"]); cam_mode = "fixed"; cam.position = v[0]; cam.look_at(v[1])
		if view == "capx": rocket.fairing.visible = false; rocket.les.visible = false
	elif cfg.mode != "spectator":
		hud.objective.text = "任务 1 / 3：按飞行程序手册给飞船加电（不限顺序，约 190 个开关全部可操作）。不熟悉可以点「开始指导」或「队友执行」"
		sfx.line("hatch", 1.0); sfx.line("seat1", 3.0)
	_update_sun()
	_load_modules()
	if "--guide" in OS.get_cmdline_user_args(): guide = true; _guide_next()
	await _step("准备就绪")
	loading.queue_free(); ready_done = true

## phones: keep the look but drop the most expensive effects and render 3D below native resolution with FSR upscaling
func _quality() -> void:
	var q: String = cfg.get("q", "balanced")
	Engine.max_fps = 120
	if q == "quality" and not OS.has_feature("mobile"): return
	if not OS.has_feature("mobile") and q == "balanced": return
	var fp := RenderingServer.get_current_rendering_method() == "forward_plus"
	RenderingServer.directional_shadow_atlas_set_size(4096 if fp else 2048, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_LOW if fp else RenderingServer.SHADOW_QUALITY_HARD)
	RenderingServer.positional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD)
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2 if fp else Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = ({"fast": 0.5, "balanced": 0.67, "quality": 0.85} if fp else {"fast": 0.6, "balanced": 0.75, "quality": 0.9}).get(q, 0.75)
	if q == "fast":
		RenderingServer.directional_shadow_atlas_set_size(2048, true)
		get_viewport().positional_shadow_atlas_size = 1024
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA

# ================= trajectory (precomputed ascent profile modelled on a CZ-2F flight) =================
# ================= plumes & smoke =================
func _build_plumes() -> void:
	var sh := load("res://shaders/plume.gdshader")
	for e in rocket.plume_points:
		var m := MeshInstance3D.new(); var cm := CylinderMesh.new(); cm.top_radius = 0.6; cm.bottom_radius = 1.4; cm.height = 1.0; cm.radial_segments = 24; cm.cap_top = false; cm.cap_bottom = false
		m.mesh = cm; var mat := ShaderMaterial.new(); mat.shader = sh; m.material_override = mat; m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		e.add_child(m); m.visible = false; plumes.append([m, e])
	smoke = GPUParticles3D.new(); smoke.amount = 900; smoke.lifetime = 14.0; smoke.emitting = false; smoke.local_coords = false
	var pm := ParticleProcessMaterial.new(); pm.direction = Vector3(1, 0.15, 0); pm.spread = 70.0; pm.initial_velocity_min = 18.0; pm.initial_velocity_max = 48.0
	pm.gravity = Vector3(0, 1.6, 0); pm.damping_min = 3.0; pm.damping_max = 6.0; pm.scale_min = 6.0; pm.scale_max = 14.0
	var curve := Curve.new(); curve.add_point(Vector2(0, 0.4)); curve.add_point(Vector2(1, 3.0)); var ct := CurveTexture.new(); ct.curve = curve; pm.scale_curve = ct
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE; pm.emission_sphere_radius = 4.0
	smoke.process_material = pm
	var q := QuadMesh.new(); q.size = Vector2(1, 1); var sm := StandardMaterial3D.new(); sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; sm.albedo_color = Color(0.82, 0.8, 0.76, 0.55); sm.albedo_texture = _puff_tex(); sm.vertex_color_use_as_albedo = true
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	q.material = sm; smoke.draw_pass_1 = q; smoke.position = Vector3(30, 2, 0)
	site.add_child(smoke)

func _puff_tex() -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 32.0
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - d, 0.0, 1.0) ** 1.6))
	return ImageTexture.create_from_image(img)

# ================= input =================
func _unhandled_input(e: InputEvent) -> void:
	if not ready_done or phase == "crew" or (cam_mode == "module" and cfg.mode != "spectator"): return
	if e is InputEventScreenTouch:
		if e.pressed: touches[e.index] = e.position; moved = 0.0
		else:
			touches.erase(e.index)
			if moved < 12.0 and touches.is_empty(): _click(e.position)
			pinch0 = 0.0
	elif e is InputEventScreenDrag:
		touches[e.index] = e.position
		if touches.size() >= 2:
			var k := touches.keys(); var d: float = (touches[k[0]] as Vector2).distance_to(touches[k[1]])
			if pinch0 > 0.0: _zoom_by(d / pinch0)
			pinch0 = d; moved = 99.0
		else: _look(e.relative * 1.4); moved += e.relative.length()
	elif e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed: _zoom_by(1.12)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed: _zoom_by(1.0 / 1.12)
		elif e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed: dragging = true; moved = 0.0
			else:
				dragging = false
				if moved < 6.0: _click(e.position)
	elif e is InputEventMouseMotion and dragging and not DisplayServer.is_touchscreen_available():
		_look(e.relative); moved += e.relative.length()
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_G: _on_button("go")
			KEY_Z: _on_button("zoom")
			KEY_V: _on_button("view")
			KEY_K: _on_button("skip")
			KEY_J: _on_button("book")

func _look(rel: Vector2) -> void:
	var k := 0.0035 / zoom
	yaw = clampf(yaw - rel.x * k, -1.6, 1.6); pitch = clampf(pitch - rel.y * k, -1.2, 1.1)

func _pick(screen: Vector2) -> String:
	var from := cam.project_ray_origin(screen); var dir := cam.project_ray_normal(screen)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 2.6, 1 << 10)
	var r := get_world_3d().direct_space_state.intersect_ray(q)
	if r.is_empty(): return ""
	return String(r.collider.get_meta("ctl", ""))

func _click(screen: Vector2) -> void:
	if cam_mode != "seat": return
	var id := _pick(screen)
	if id == "": return
	sfx.click()
	if id.begins_with("MFD"):
		if has_meta("mfd"): get_meta("mfd").cycle(int(id.substr(3)))
		return
	var msg := console.operate(id)
	if msg != "": hud.say("系统", msg, 2.5)
	if id == "ABORT": _abort_pressed()

func _on_button(n: String) -> void:
	match n:
		"go":
			if wait_go: wait_go = false; crew_go = true; sfx.line("gome", 0.0, true); _later(3.5, func(): sfx.line("resume"); running = true; hud.objective.text = "倒计时：躺稳，看着面板")
		"zoom": zoom = 1.0 if zoom > 1.2 else 2.5
		"view":
			if cfg.mode == "spectator": spec_track = not spec_track; hud.say("系统", "自动跟踪火箭：" + ("开" if spec_track else "关"), 1.5)
			else: cam_mode = "chase" if cam_mode == "seat" else "seat"
		"skip":
			if not lifted:
				console.auto_upto("int"); poll_done = true; wait_go = false; crew_go = true; running = true; T = maxf(T, -12.0); hud.say("系统", "已跳到 T−12 秒", 2.0)
		"book": hud.proc_box.visible = not hud.proc_box.visible
		"prev": ph = (ph + CD.PROC.size() - 1) % CD.PROC.size(); _stop_guide()
		"next": ph = (ph + 1) % CD.PROC.size(); _stop_guide()
		"guide":
			if guide and not crew_exec: _stop_guide()
			else: guide = true; crew_exec = false; sfx.line("c_gd", 0.0, true); _later(1.4, func(): sfx.line("pi_" + CD.PROC[ph].k); _guide_next())
		"crew":
			if crew_exec: _stop_guide()
			else: guide = true; crew_exec = true; crew_timer = 1.6; sfx.line("c_crew", 0.0, true); _later(1.4, func(): sfx.line("pi_" + CD.PROC[ph].k))

func _stop_guide() -> void: guide = false; crew_exec = false; guide_step = []

func _next_step() -> Array:
	for st in CD.PROC[ph].s:
		if st[0] != "@eq" and not console.SW.has(st[0]): continue
		if not console.step_ok(st): return st
	return []

func _guide_next() -> void:
	if not guide: return
	var st := _next_step()
	if st.is_empty(): sfx.line("pd_" + CD.PROC[ph].k); _stop_guide(); return
	if guide_step != st:
		guide_step = st
		if st[0] == "@eq": sfx.line("k_eq")
		else: sfx.line("k_%s_%s" % [st[0], str(st[1])])

func _on_caution(level: String, msg: String) -> void:
	hud.say("主告警" if level == "W" else ("注意" if level == "C" else "系统"), msg, 4.0)

func _abort_pressed() -> void:
	for m in modules:
		if m.has_method("abort_request") and m.abort_request(): return
	if lifted and stage < 2 and console.esc_hw():
		hud.say("系统", "逃逸！逃逸塔点火", 4.0); sfx.line("xabort", 0.0, true); _abort()
	elif not lifted and T > -120.0 and running:
		hud.say("系统", "发射中止", 3.0); running = false; held = "abort"

func _abort() -> void:
	stage = 9; throttle = 0.0

# ================= timers =================
var _timers: Array = []
func _later(sec: float, cb: Callable) -> void: _timers.append([sec, cb])

# ================= main loop =================
func _process(dt: float) -> void:
	if not ready_done: return
	frames += 1
	for m in modules: m.tick(dt)
	_place_earth.call_deferred()
	if shot != "" and frames == 50: get_viewport().get_texture().get_image().save_png(shot); get_tree().quit()
	for i in range(_timers.size() - 1, -1, -1):
		_timers[i][0] -= dt
		if _timers[i][0] <= 0.0: var cb: Callable = _timers[i][1]; _timers.remove_at(i); cb.call()
	# mission context for the systems model
	console.phase = "ascent" if lifted and stage < 3 else ("orbit" if stage == 3 else "prelaunch")
	console.on_ground_power = not lifted
	console.in_space = alt > 100000.0
	console.tick(dt)
	sfx.comm_ok = console.comm_link(not lifted or T < 420.0 or phase in ["entry", "landed", "abort"], phase in ["rdv", "docked"]) and not bool(get_meta("comm_loss", false))
	sfx.set_alarm(console.alarm_on and console.cws_ok())
	_count(dt)
	_flight(dt)
	_camera(dt)
	_ui(dt)
	if guide and crew_exec:
		crew_timer -= dt
		if crew_timer <= 0.0:
			crew_timer = 1.2
			var st := _next_step()
			if st.is_empty(): sfx.line("pd_" + CD.PROC[ph].k); _stop_guide()
			elif st[0] != "@eq":
				var c: Dictionary = console.cells.get(st[0], {})
				if not c.is_empty() and (c.kind == "g" or c.kind == "gp") and not c.open: console.operate(st[0])
				elif typeof(st[1]) != TYPE_STRING and console.S.get(st[0], false) == (int(st[1]) == 1):
					for p in ["cb_", "cb2_"]: if console.S.has(p + st[0]) and not console.S[p + st[0]]: console.set_switch(p + st[0], true)
				else: console.operate(st[0])
				sfx.click()
	elif guide: _guide_next()

func _count(dt: float) -> void:
	if lifted: return
	# launch poll once the spacecraft is configured
	if not poll_done and console.lcc_fails().is_empty():
		poll_done = true; hud.objective.text = "任务 2 / 3：发射主任正在逐一确认各岗位状态"
		for i in 6: sfx.line("poll%d" % i, 0.6 if i > 0 else 2.0)
		_later(19.0, func(): wait_go = true; hud.objective.text = "发射主任在等你的回复：点「回复 GO」（G 键）")
	if not running: return
	var T0 := T; T += dt
	# terminal count holds if launch commit criteria are violated
	if T > -60.0 and not console.lcc_fails().is_empty():
		running = false; held = "lcc"; sfx.line("c_lcc", 0.0, true); console.alarm_on = true; return
	if T > -15.0 and not console.internal_power():
		running = false; held = "int"; sfx.line("c_holdpwr", 0.0, true); ph = _proc_index("int"); return
	var ev := {-59.9: "term", -45.0: "c_zd", -40.0: "power", -30.0: "les", -25.0: "umb", -20.0: "go", -16.0: "deluge"}
	for k in ev: if T0 < k and T >= k and cfg.mode != "spectator": sfx.line(ev[k]); if ev[k] == "c_zd": ph = _proc_index("int")
	for n in range(10, 0, -1):
		if T0 < -n and T >= -n and cfg.mode != "spectator": sfx.line("n%d" % n, 0.0, true)
	if T0 < -16.0 and T >= -16.0: pass
	if T >= -3.0 and throttle == 0.0: throttle = 0.4
	if T0 < 0.0 and T >= 0.0 and cfg.mode != "spectator": sfx.line("ign", 0.0, true)
	if T >= 2.0:
		lifted = true
		if cfg.mode == "spectator": phase = "ascent"
		else: set_phase("ascent"); sfx.line("lift", 0.3, true); hud.objective.text = "起飞！"

func _proc_index(k: String) -> int:
	for i in CD.PROC.size(): if CD.PROC[i].k == k: return i
	return 0

var flight: Flight
var ff := false          # fast-forwarding (debug --flight=): no voice
var jolt := 0.0
var _said_t := {}

func _flight(dt: float) -> void:
	if not lifted:
		throttle = minf(throttle + dt * 0.25, 1.0) if throttle > 0.0 else 0.0
		alt = 0.0; vel = 0.0; gload = 1.0
		shake = throttle * 0.004
		if cfg.mode != "spectator": sfx.set_engine(throttle * 0.85, cam_mode == "seat")
		return
	if stage == 9 or (phase != "ascent" and phase != "spectator"): return
	T += dt
	if flight == null: flight = Flight.new(rocket.kind); set_meta("flight", flight)
	flight.engine_out = int(get_meta("engine_out", 0))
	flight.step(dt)
	var st: Dictionary = flight.state
	var t: float = flight.t
	# floating origin: the rocket stays at (0, DECK, 0); the site moves underneath
	var p: Vector3 = st.pos
	site.position = -p
	var d: Vector3 = st.dir
	rocket.transform = Transform3D(Basis(Vector3(0, 0, 1), -atan2(d.x, d.y)), Vector3(0, Pad.DECK, 0))
	alt = st.alt; vel = st.speed; gload = st.g; qdyn = st.q; set_meta("mach", st.mach)
	for e in flight.events: _event(e)
	for k in [[8.0, "tower"], [20.0, "feel"], [300.0, "nom"]]:
		if t >= k[0] and not _said_t.has(k[1]): _said_t[k[1]] = true; _event(k[1])
	if flight.phase == 4 and not _said_t.has("shipsep") and not _said_t.has("seco_t"): _said_t["seco_t"] = t
	if _said_t.has("seco_t") and t - float(_said_t["seco_t"]) > 6.0 and not _said_t.has("shipsep"): _said_t["shipsep"] = true; _event("shipsep")
	throttle = 0.0 if flight.phase == 2 or flight.phase == 4 else (0.12 if flight._vern else 1.0)
	jolt = maxf(0.0, jolt - dt * 1.5)
	var buffet := clampf(qdyn / 35000.0, 0.0, 1.0)
	shake = (0.0008 + 0.0015 * (st.thrust / 6.0e6) + 0.006 * buffet * buffet + (0.004 if t < 10.0 else 0.0)) * (1.0 if throttle > 0.0 else 0.2) + jolt * 0.02
	if cfg.mode != "spectator": sfx.set_engine(throttle, cam_mode == "seat", buffet)
	# world fades: terrain -> globe; sky -> black
	var ef := smoothstep(12000.0, 45000.0, alt)
	earth.set_fade(ef); world.terrain.visible = alt < 90000.0; pad.visible = alt < 30000.0
	world.sky_mat.energy_multiplier = lerpf(1.0, 0.04, smoothstep(10000.0, 70000.0, alt))
	world.env.fog_density = 0.000022 * (1.0 - smoothstep(2000.0, 20000.0, alt)) + float(get_meta("cloud_fog", 0.0))
	world.env.volumetric_fog_enabled = alt < 15000.0 and not OS.has_feature("mobile")
	# debris falls in the site frame: gravity + drag
	for dd in detached:
		var n: Node3D = dd[0]
		if not n.get_parent() == site: continue
		var rho := 1.225 * exp(-n.position.y / 8400.0)
		var vv: Vector3 = dd[1]; vv += Vector3(0, -9.8, 0) * dt - vv * minf(1.0, rho * vv.length() * 0.0004) * dt
		dd[1] = vv; n.position += vv * dt; n.rotate(dd[2], dt * 0.5)
	_update_sun()

func _event(k: String) -> void:
	if cfg.mode != "spectator" and not ff: sfx.line(k)
	match k:
		"lesj": _detach(rocket.les, Vector3(-6, 40, 3)); jolt = 0.5
		"bsep":
			for b in rocket.boosters: _detach(b, (b.global_position - rocket.global_position).normalized() * 6.0 + Vector3(0, -4, 0))
			stage = 1; jolt = 1.0
		"meco": jolt = 0.6
		"sep": _detach(rocket.stage1, Vector3(0, -12, 0)); stage = 2; jolt = 1.2
		"fair": _detach(rocket.fairing, Vector3(4, 0, 10)); _open_windows(); jolt = 0.4
		"seco": jolt = 0.4
		"underspeed": hud.say("指挥大厅", "二级推进剂耗尽，入轨速度不足！", 5.0)
		"shipsep": stage = 3; jolt = 0.5; hud.objective.text = "入轨成功！船箭分离。欢迎来到太空。"; set_phase("orbit")

## separated parts continue in the site frame with the vehicle's velocity plus a separation push
func _detach(n: Node3D, push: Vector3) -> void:
	if n == null or n.get_parent() == null: return
	var gt := n.global_transform; n.get_parent().remove_child(n); site.add_child(n); n.global_transform = gt
	var v0: Vector3 = flight.state.vel if flight else Vector3.ZERO
	detached.append([n, v0 + rocket.global_transform.basis * push, Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()])

func _open_windows() -> void:
	for c in capsule.get_children():
		if c.has_meta("cover"): (c.get_meta("cover") as Node3D).visible = false

func _plumes_update(dt: float) -> void:
	var thin := smoothstep(0.0, 60000.0, alt)
	for p in plumes:
		var m: MeshInstance3D = p[0]; var e: Node3D = p[1]
		var attached := e.is_inside_tree() and not _is_detached(e)
		m.visible = throttle > 0.01 and attached and (stage < 2 or e.get_parent().get_parent() == rocket.stage2 or e.get_parent() == rocket.stage2)
		if not m.visible: continue
		var L := (12.0 + 30.0 * thin) * throttle; var w := 1.0 + 5.0 * thin
		m.scale = Vector3(w, L, w); m.position = Vector3(0, -L * 0.5, 0)
		(m.material_override as ShaderMaterial).set_shader_parameter("thin", thin)

func _is_detached(n: Node) -> bool:
	var p := n
	while p != null:
		for d in detached: if d[0] == p: return true
		p = p.get_parent()
	return false

func _update_sun() -> void:
	var d := -world.sun.global_transform.basis.z
	earth.set_sun(-d)

func _camera(dt: float) -> void:
	if cam_mode == "fixed" or cam_mode == "module": return
	if view.begins_with("cabin"):
		var parts := view.split(":")
		if parts.size() > 2: yaw = float(parts[1]); pitch = float(parts[2])
	var fov := 74.0 / zoom
	if cam_mode == "seat":
		var base := capsule.seat_anchor.global_transform
		var b := base.basis * Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
		cam.global_transform = Transform3D(b, base.origin)
		if shake > 0.0:
			cam.rotate_object_local(Vector3.RIGHT, randf_range(-shake, shake)); cam.rotate_object_local(Vector3.UP, randf_range(-shake, shake))
	else:
		var tgt := rocket.global_position + rocket.global_transform.basis.y * 30.0
		var dir := Vector3(sin(yaw), 0.25 + pitch * 0.57, cos(yaw)).normalized()
		# never closer than 1 m to the hull: distance is measured from the body surface, not the axis
		var d := maxf(cdist, _body_r() + 1.0)
		cam.global_position = tgt + dir * d; cam.look_at(tgt, Vector3.UP)
		fov = 55.0 / zoom
	cam.fov = lerpf(cam.fov, fov, minf(1.0, dt * 8.0))

var gring: MeshInstance3D
## yellow pulsing ring around the switch the guide wants next (drawn on top of everything)
func _guide_ring(_dt: float) -> void:
	if gring == null:
		gring = MeshInstance3D.new(); var tm := TorusMesh.new(); tm.inner_radius = 0.036; tm.outer_radius = 0.044; tm.rings = 32; tm.ring_segments = 8; gring.mesh = tm
		var m := StandardMaterial3D.new(); m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; m.no_depth_test = true; m.render_priority = 10
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; m.albedo_color = Color(1.0, 0.85, 0.1, 0.95); gring.material_override = m
		gring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; add_child(gring)
	var id: String = String(guide_step[0]) if guide and not guide_step.is_empty() else ""
	if id == "" or id == "@eq" or not console.cells.has(id) or not console.cells[id].has("hit") or cam_mode != "seat":
		gring.visible = false; hud.garrow.visible = false; return
	var h: Node3D = console.cells[id].hit
	gring.visible = true
	var s := 1.0 + 0.15 * sin(Time.get_ticks_msec() * 0.008)
	gring.global_transform = Transform3D(h.global_basis.orthonormalized() * Basis(Vector3.RIGHT, PI * 0.5) * Basis().scaled(Vector3(s, s, s)), h.global_position + h.global_basis.z.normalized() * 0.02)
	# off-screen: an arrow at the screen edge points the way (turn your head toward it)
	var vs := get_viewport().get_visible_rect().size
	var behind := cam.is_position_behind(h.global_position)
	var sp := cam.unproject_position(h.global_position)
	var inside := not behind and Rect2(Vector2(40, 40), vs - Vector2(80, 80)).has_point(sp)
	hud.garrow.visible = not inside
	if not inside:
		var c := vs * 0.5; var d := (sp - c) * (-1.0 if behind else 1.0)
		if d.length() < 1.0: d = Vector2(1, 0)
		var k := minf((vs.x * 0.5 - 50.0) / maxf(absf(d.x), 0.001), (vs.y * 0.5 - 50.0) / maxf(absf(d.y), 0.001))
		hud.garrow.position = c + d * k - Vector2(30, 30); hud.garrow.rotation = d.angle()
		hud.garrow.modulate.a = 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.008)

func _body_r() -> float:
	if stage >= 3: return 2.4
	return {"saturn": 5.6, "fh": 6.6, "shuttle": 12.5}.get(rocket.kind, 2.6)

func _zoom_by(f: float) -> void:
	if cam_mode == "seat": zoom = clampf(zoom * f, 1.0, 4.0)
	else: cdist = clampf(cdist / f, _body_r() + 1.0, 3000.0)

func _ui(dt: float) -> void:
	hud.clock.text = Hud.fmt_t(T)
	if frames % 20 == 0: hud.fps.text = "%d FPS" % Engine.get_frames_per_second()
	_guide_ring(dt)
	var st := "倒计时" if running and not lifted else ("计划内暂停 · HOLD" if not lifted else "上升段")
	if held == "lcc": st = "计数暂停：发射条件不满足"
	elif held == "int": st = "计数暂停：器上未转电"
	if stage == 3: st = "在轨飞行 · 失重"
	hud.phase_l.text = st
	hud.tele.text = "高度  %.1f km\n速度  %d km/h\n过载  %.2f g\n动压  %.1f kPa\n舱压  %.1f kPa" % [alt / 1000.0, int(vel * 3.6), gload, qdyn / 1000.0, console.cabP]
	hud.go_btn.visible = wait_go
	if held != "" and console.lcc_fails().is_empty() and (held == "lcc" or console.internal_power()):
		held = ""; _later(2.0, func(): running = true; sfx.line("holdres"))
	# procedure book
	var P: Dictionary = CD.PROC[ph]
	hud.proc_title.text = "%d/%d %s · %s" % [ph + 1, CD.PROC.size(), P.n, P.w]
	var nx: Array = _next_step() if guide else []
	var txt := ""
	for s in P.s:
		var id: String = s[0]
		if id != "@eq" and not console.SW.has(id): continue
		var ok := console.step_ok(s); var nm := "等待压差归零"
		if id != "@eq":
			var d: Dictionary = console.SW[id]; var vb: Array = CD.VERB_X.get(id, CD.VERB[d.kind])
			nm = "%s · %s  [color=#8899aa]%s[/color]" % [d.cn, vb[1] if (typeof(s[1]) != TYPE_STRING and int(s[1]) == 0) else vb[0], d.en]
		var mark := "[color=#5ef29a]✓[/color]" if ok else ("[color=#ffd060]▸[/color]" if s == nx else "○")
		txt += "%s %s\n" % [mark, ("[color=#5ef29a]%s[/color]" % nm) if ok else nm]
	hud.proc_list.text = txt
	var lf := console.lcc_fails()
	var cw := ""
	if not lifted: cw += ("[color=#ffb24a]发射条件未满足 %d 项[/color]\n" % lf.size()) if lf.size() > 0 else "[color=#5ef29a]发射条件全部满足[/color]\n"
	if console.cws_ok():
		for a in console.cw_active.slice(0, 5):
			cw += ("[color=#ff6a4a]▲ %s[/color]\n" if a[1] == "W" else "[color=#ffb24a]△ %s[/color]\n") % a[2]
	hud.cw_list.text = cw
	hud.btn_guide.text = "停止指导" if guide and not crew_exec else "开始指导"
	hud.btn_crew.text = "停止" if crew_exec else "队友执行"
	# tooltip under the crosshair
	if cam_mode == "seat" and frames % 6 == 0:
		var id := _pick(get_viewport().get_visible_rect().size * 0.5)
		if id == "" or id.begins_with("MFD"): hud.tip.text = "多功能显示器 · 点击切换页面" if id != "" else ""
		else:
			var d := console.def_of(id); var k := console.kind_of(id); var on: bool = console.S.get(id, false)
			var state := ""
			if k == "c": state = "断路器 " + ("闭合 IN" if on else "拉出 OUT") + (" · 已跳闸" if console.tripped.has(id) else "")
			elif k == "p" or k == "gp": state = ("带保护盖 · 先点开盖" if k == "gp" and not console.cells[id].open else "按钮") + (" · 已执行" if console.step_push_done(id) else "")
			else:
				var vb: Array = CD.VERB_X.get(id, CD.VERB[k]); state = vb[0] if on else vb[1]
				if on and d.bus != null and not console.pw(id): state += " · 无电"
				if k == "g" and not console.cells[id].open: state += " · 先点开保护盖"
			hud.tip.text = "%s · %s\n%s" % [d.cn, d.en, state]
	hud.cross.visible = cam_mode == "seat"
	if cfg.mode == "spectator": hud.proc_box.visible = false

func _place_earth() -> void:
	if earth and earth.visible: earth.place(cam.global_position, site.global_position + Vector3(0, -Earth.R, 0))

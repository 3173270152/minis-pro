## Return & aborts: deorbit sequence gated by the console, physics entry (CapsuleFlight) with plasma, blackout and g-load,
## drogue/main chutes (ELS auto or manual), heat-shield jettison, soft-landing retros, recovery helicopters, hatch, end card.
## Also the launch disasters (hold, comm loss, cabin alarm, engine out, pad abort, pad explosion, max-Q breakup, LES failure,
## chute failure, retro failure) and the launch-escape flight.
extends Node3D

const CF := preload("res://scripts/capsule_flight.gd")
var g
var cf
var phase := ""
var t := 0.0
var step_i := 0
var wait_msg_t := 0.0
var plasma: MeshInstance3D
var canopy: Node3D
var drogue: Node3D
var cabin_glow: OmniLight3D
var chute := ""            # "", drogue, main, failed
var shield_off := false
var landed_t := -1.0
var heli: Array = []
var endcard: CanvasLayer
var dis := ""
var dis_t := 0.0
var dis_done := false
var abort_window := -1.0
var boom: GPUParticles3D
var gmax := 0.0
var outcome := ""
var land_pos := Vector3.ZERO

func setup(game) -> void:
	g = game
	g.phase_changed.connect(_on_phase)
	_pick_disaster()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--entry="): g._later(0.6, func(): _debug(a.substr(8)))

# ---------------- disasters ----------------
const DIS := {"hold": "minor", "commLoss": "minor", "cabinAlarm": "minor", "engineOut": "moderate", "padAbort": "moderate", "chuteFail": "moderate", "retroFail": "moderate", "padExplosion": "severe", "maxqBreakup": "severe", "lesFail": "severe"}
func _pick_disaster() -> void:
	var d: String = g.cfg.get("dis", "off")
	if DIS.has(d): dis = d
	elif d != "off":
		var lv: String = d if d in ["minor", "moderate", "severe"] else ["minor", "moderate", "severe"][randi() % 3]
		var ks := DIS.keys().filter(func(k): return DIS[k] == lv); dis = ks[randi() % ks.size()]
	dis_t = {"hold": -31.0, "commLoss": 80.0, "cabinAlarm": 250.0, "engineOut": 60.0, "padAbort": -1.0, "padExplosion": 3.0, "maxqBreakup": 72.0, "lesFail": 72.0}.get(dis, 1e9)
	if dis != "": print("[disaster] ", dis)

func _disaster_tick() -> void:
	if dis_done or dis == "" or g.phase not in ["seat", "ascent", "spectator"]: return
	if g.T < dis_t or (dis_t < 0.0 and not g.running): return
	dis_done = true
	match dis:
		"hold": g.running = false; g.sfx.line("hold", 0.0, true); g.console.alarm_on = true; g._later(18.0, func(): g.sfx.line("holdres"); g._later(3.0, func(): g.running = true))
		"commLoss": g.set_meta("comm_loss", true); g.hud.say("系统", "……通信中断……", 4.0); g._later(12.0, func(): g.set_meta("comm_loss", false); g.sfx.line("commback"))
		"cabinAlarm": g.console.alarm_on = true; g.sfx.line("alarmme", 0.0, true); g.sfx.line("alarm", 2.0)
		"engineOut": g.set_meta("engine_out", 1); g.sfx.line("eo", 0.0, true); g.sfx.line("eome", 2.0); g.console.alarm_on = true
		"padAbort": g.running = false; g.throttle = 0.0; g.held = "abort"; g.sfx.line("padabort", 0.0, true); g.console.alarm_on = true; g._later(6.0, func(): g.sfx.line("padabort2")); g._later(25.0, func(): _end("发射中止", "点火后发动机参数异常，自动关机。火箭仍在发射台上，乘组安全。"))
		"padExplosion", "maxqBreakup", "lesFail": _breakup()

func _breakup() -> void:
	_explosion(g.rocket.global_position + g.rocket.global_transform.basis.y * 15.0)
	g.console.alarm_on = true; g.sfx.line("alarm", 0.0, true)
	var auto_esc: bool = g.console.pw("ABTAUTO")
	if dis == "lesFail" or not g.console.esc_hw():
		_crew_loss(); return
	if auto_esc: _escape()
	else:
		abort_window = 3.0; g.hud.say("主告警", "火箭解体！自动中止未启用 —— 3 秒内按「中止」！", 3.0); g.sfx.line("c_manab", 0.0, true)

## main calls this when the ABORT button is pressed during ascent (via abort_request)
func abort_request() -> bool:
	if abort_window > 0.0: abort_window = -1.0; _escape(); return true
	if g.lifted and g.stage < 2 and g.console.esc_hw() and phase == "": _escape(); return true
	return false

func _escape() -> void:
	phase = "abort"; g.set_phase("abort"); g.stage = 9; g.throttle = 0.0; g.cam_mode = "seat"
	g.sfx.line("xabort", 0.0, true); g.sfx.line("abortme", 2.0)
	cf = CF.new()
	var st: Dictionary = g.flight.state if g.flight else {"pos": Vector3.ZERO, "vel": Vector3.ZERO}
	cf.set_pos(st.pos + Vector3(0, Pad.DECK + g.rocket.y_cap, 0)); cf.v = st.vel; cf.ld = 0.0; cf.guided = false
	cf.thrust = g.rocket.global_transform.basis.y * 12.0 * 9.81
	t = 0.0
	for n in [g.rocket.stage1, g.rocket.stage2]:
		if n and n.get_parent() == g.rocket: g._detach(n, Vector3(0, -5, 0))
	for b in g.rocket.boosters: if b.get_parent() != g.site: g._detach(b, Vector3(0, -5, 0))

func _crew_loss() -> void:
	phase = "lost"; g.stage = 9
	g._later(1.5, func(): g.sfx.line("lost", 0.0, true); _fade_black())
	g._later(6.0, func(): _end("乘组遇难", "火箭解体，逃逸系统未能工作（逃逸塔/火工品未预位，或逃逸失效）。真实飞行中逃逸系统在发射前必须预位。", true))

func _explosion(at: Vector3) -> void:
	boom = GPUParticles3D.new(); boom.amount = 400; boom.lifetime = 6.0; boom.one_shot = true; boom.explosiveness = 0.9; boom.local_coords = false
	var pm := ParticleProcessMaterial.new(); pm.direction = Vector3.UP; pm.spread = 180.0; pm.initial_velocity_min = 20.0; pm.initial_velocity_max = 90.0; pm.damping_min = 6.0; pm.damping_max = 12.0
	pm.scale_min = 6.0; pm.scale_max = 16.0; pm.gravity = Vector3(0, 2, 0)
	var gr := Gradient.new(); gr.set_color(0, Color(1.0, 0.9, 0.6)); gr.add_point(0.15, Color(1.0, 0.45, 0.1)); gr.set_color(gr.get_point_count() - 1, Color(0.15, 0.13, 0.12, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = gr; pm.color_ramp = gt; boom.process_material = pm
	var q := QuadMesh.new(); var m := StandardMaterial3D.new(); m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES; m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true; m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; m.albedo_texture = U.puff_tex()
	q.material = m; boom.draw_pass_1 = q; add_child(boom); boom.global_position = at; boom.emitting = true
	var fl := OmniLight3D.new(); fl.light_color = Color(1, 0.6, 0.3); fl.light_energy = 30.0; fl.omni_range = 600.0; add_child(fl); fl.global_position = at
	create_tween().tween_property(fl, "light_energy", 0.0, 3.0)

# ---------------- deorbit ----------------
func _on_phase(p: String) -> void:
	if p == "deorbit" and phase == "": phase = "deorbit"; step_i = 0; t = 0.0

func _debug(m: String) -> void:
	g.console.auto_upto("deo"); g.stage = 3; g.lifted = true
	match m:
		"deorbit": g.set_phase("deorbit")
		"entry", "plasma", "chute", "landed":
			phase = "deorbit"; _start_entry()
			var target_h: float = {"entry": 115000.0, "plasma": 60000.0, "chute": 9000.0, "landed": 150.0}[m]
			while cf.alt > target_h and cf.t < 3000.0: cf.step(0.5); _chutes(0.5)

func _deorbit_tick(dt: float) -> void:
	t += dt
	var c = g.console
	var site_pos := Vector3.ZERO
	match step_i:
		0:
			if t > 3.0:
				if c.pyro_ok() or c.pushed.get("SEPSM", false):
					step_i = 1; t = 0.0; g.sfx.line("omsep"); _hide_om()
				elif t - wait_msg_t > 20.0: wait_msg_t = t; g.sfx.line("c_sep"); g.hud.say("系统", "轨道舱未分离：检查程序控制器与火工品，或按「舱段分离」", 4.0)
		1:
			if t > 6.0:
				if c.deo_ready():
					step_i = 2; t = 0.0; g.sfx.line("deorb"); g.throttle = 0.0; g.hud.objective.text = "制动点火中……"
				elif t - wait_msg_t > 20.0: wait_msg_t = t; g.sfx.line("c_deoh"); g.hud.say("系统", "离轨条件不满足：轨控发动机预位、离轨程序、推进剂隔离阀、制导与惯组、姿控", 5.0)
		2:
			g.shake = 0.0015
			if t > 30.0: step_i = 3; t = 0.0; g.sfx.line("deorb2"); g.shake = 0.0
		3:
			if t > 2.0 and (c.pyro_ok() or c.pushed.get("SEPSM", false)):
				step_i = 4; t = 0.0; _hide_sm(); g.sfx.line("r2")
		4:
			if t > 6.0: step_i = 5; _fade_black(); g._later(1.0, func(): _start_entry(); _fade_in())

func _hide_om() -> void:
	for n in g.rocket.get_children():
		if n is Node3D and n.position.y > g.rocket.y_cap + 2.0 and n != g.rocket.cap_mount and not n.is_ancestor_of(g.capsule): n.visible = false

func _hide_sm() -> void:
	for n in g.rocket.get_children():
		if n is Node3D and n.has_meta("sa"): n.visible = false

func _start_entry() -> void:
	phase = "entry"; g.set_phase("entry"); g.cam_mode = "seat"
	cf = CF.new()
	var ballistic: bool = g.console.gnc_n() == 0 or g.console.imu_n() == 0
	cf.ld = 0.0 if ballistic else 0.3; cf.guided = not ballistic
	# choose the entry point so the capsule comes down ~35 km downrange of the launch site
	var phi0 := -0.16
	for k in 6:
		cf.set_orbit(phi0, 120000.0, 7600.0, deg_to_rad(-1.4))
		var f = cf.copy(); var n := 0
		while f.alt > 9000.0 and n < 3000: f.step(1.0); n += 1
		phi0 += (35000.0 / Earth.R) - f.phi()
	cf.set_orbit(phi0, 120000.0, 7600.0, deg_to_rad(-1.4))
	if ballistic: g._later(3.0, func(): g.sfx.line("c_ball"))
	g.sfx.line("entry", 1.0)
	g.hud.objective.text = "再入大气层：防热大底朝前，舷窗外将出现等离子体火光"
	_build_entry_fx()

func _build_entry_fx() -> void:
	if plasma: return
	plasma = MeshInstance3D.new(); var sm := SphereMesh.new(); sm.radius = 2.4; sm.height = 3.2; plasma.mesh = sm
	var m := ShaderMaterial.new(); m.shader = load("res://shaders/plume.gdshader"); m.set_shader_parameter("layer", 1.0); m.set_shader_parameter("thin", 0.6)
	m.set_shader_parameter("hot", Color(1.0, 0.75, 0.5)); m.set_shader_parameter("mid", Color(1.0, 0.4, 0.75)); m.set_shader_parameter("tail", Color(0.6, 0.2, 0.8))
	plasma.material_override = m; plasma.position = Vector3(0, g.rocket.y_cap - 0.6, 0); g.rocket.add_child(plasma)
	cabin_glow = OmniLight3D.new(); cabin_glow.light_color = Color(1.0, 0.55, 0.3); cabin_glow.omni_range = 3.0; cabin_glow.light_energy = 0.0
	g.capsule.add_child(cabin_glow); cabin_glow.position = Vector3(0, 1.0, 0)
	canopy = _chute_mesh(14.0, Color(0.95, 0.4, 0.15), Color(1, 1, 1)); drogue = _chute_mesh(3.0, Color(1, 1, 1), Color(0.9, 0.3, 0.1))

func _chute_mesh(r: float, c1: Color, c2: Color) -> Node3D:
	var n := Node3D.new(); n.visible = false; g.rocket.add_child(n); n.position = Vector3(0, g.rocket.y_cap + 2.2 + r * 2.2, 0)
	for k in 12:
		var gore := MeshInstance3D.new(); var sp := SphereMesh.new(); sp.radius = r; sp.height = r * 1.2; sp.is_hemisphere = true; sp.radial_segments = 4; sp.rings = 6
		gore.mesh = sp; var mm := U.mat(c1 if k % 2 == 0 else c2, 0.9); mm.cull_mode = BaseMaterial3D.CULL_DISABLED; gore.material_override = mm
		gore.rotation.y = TAU * k / 12.0; n.add_child(gore)
	for k in 12:
		var a := TAU * k / 12.0
		U.beam(n, Vector3(sin(a) * r, 0, cos(a) * r), Vector3(0, -r * 2.2, 0), 0.02, U.mat(Color(0.9, 0.9, 0.9), 0.8))
	return n

func _chutes(dt: float) -> void:
	var c = g.console
	if chute == "" and cf.alt < 10000.0:
		if c.els_auto(): _drogue()
		elif c.pushed.get("DROGUE", false) and c.pyro_man_ok(): _drogue()
		elif c.pushed.get("CHUTE", false) and c.pyro_man_ok(): _main()
		elif fmod(cf.t, 10.0) < dt: g.sfx.line("c_chman", 0.0, true); g.console.alarm_on = true
	elif chute == "drogue" and (cf.alt < 6000.0 and c.els_auto() or c.pushed.get("CHUTE", false) and c.pyro_man_ok()):
		_main()
	elif chute == "failed" and (c.pushed.get("CHUTE", false) and c.pyro_man_ok() or c.els_auto() and cf.t - dis_t > 8.0):
		chute = "main"; cf.chute_goal = 900.0; cf.chute_rate = 300.0; canopy.visible = true; g.sfx.line("chutefail2")
	if chute == "main" and not shield_off and cf.alt < 5000.0 and c.els_auto(): shield_off = true; g.sfx.line("shield")

func _drogue() -> void:
	chute = "drogue"; cf.chute_goal = 28.0; cf.chute_rate = 30.0; drogue.visible = true; g.sfx.line("drogue"); g.shake = 0.01

func _main() -> void:
	drogue.visible = false
	if dis == "chuteFail" and not dis_done:
		dis_done = true; chute = "failed"; dis_t = cf.t; g.sfx.line("chutefail", 0.0, true); g.console.alarm_on = true; return
	chute = "main"; cf.chute_goal = 1100.0; cf.chute_rate = 250.0; canopy.visible = true; g.sfx.line("main"); g.shake = 0.012

func _flight_tick(dt: float) -> void:
	var n := maxi(1, int(dt / 0.02))
	for k in n:
		cf.step(dt / n)
	if phase == "abort" and cf.t > 3.0: cf.thrust = Vector3.ZERO
	_chutes(dt)
	var p: Vector3 = cf.pos()
	g.site.position = -(p - Vector3(0, Pad.DECK + g.rocket.y_cap, 0))
	g.alt = cf.alt; g.vel = cf.v.length(); g.gload = maxf(cf.g, 0.0); g.qdyn = cf.q; gmax = maxf(gmax, cf.g)
	# heat shield into the flow; under chutes the capsule hangs upright
	var vd: Vector3 = -cf.v.normalized() if cf.v.length() > 1.0 else Vector3.UP
	var want := U.basis_from_y(vd) if chute != "main" else U.basis_from_y(cf.up)
	g.rocket.transform = Transform3D(g.rocket.transform.basis.slerp(want, minf(1.0, dt * 1.5)).orthonormalized(), Vector3(0, Pad.DECK, 0))
	var heat := clampf(cf.heat, 0.0, 1.5)
	if plasma:
		plasma.visible = heat > 0.05
		(plasma.material_override as ShaderMaterial).set_shader_parameter("power", heat * 1.4)
		cabin_glow.light_energy = heat * 2.0
	for c in g.capsule.get_children(): if c.has_meta("cover"): (c.get_meta("cover") as Node3D).visible = false
	g.set_meta("comm_loss", heat > 0.6)
	g.shake = 0.002 + heat * 0.006 + clampf(cf.q / 30000.0, 0.0, 1.0) * 0.004 + (0.004 if chute != "" and cf.t < 0.0 else 0.0)
	# Earth / terrain / sky fades as we come down
	var a: float = cf.alt
	g.earth.set_fade(smoothstep(12000.0, 45000.0, a)); g.world.terrain.visible = a < 90000.0; g.pad.visible = a < 30000.0
	g.world.sky_mat.energy_multiplier = lerpf(1.0, 0.04, smoothstep(10000.0, 70000.0, a)); g.world.env.fog_enabled = a < 30000.0
	g.world.env.fog_density = 0.000022 * (1.0 - smoothstep(2000.0, 20000.0, a))
	# touchdown on the baked terrain
	var gh: float = g.world.height(p.x, p.z)
	if p.y - (Pad.DECK + g.rocket.y_cap) <= gh + 0.3 and cf.v.dot(cf.up) < 0.0 and cf.alt < 3000.0: _touchdown(gh)

func _touchdown(gh: float) -> void:
	var vz: float = absf(cf.v.dot(cf.up))
	var retro: bool = g.console.retro_ok() and dis != "retroFail"
	land_pos = cf.pos()
	phase = "landed"; landed_t = 0.0; g.set_phase("landed"); g.shake = 0.0
	canopy.visible = false; drogue.visible = false; plasma.visible = false; cabin_glow.light_energy = 0.0
	g.rocket.transform = Transform3D(Basis(Vector3(0, 0, 1), 0.08), Vector3(0, Pad.DECK, 0))
	if chute == "" or chute == "failed" or vz > 18.0:
		_explosion(g.rocket.global_position); _crew_loss(); return
	if retro: g.sfx.line("land", 0.0, true); _dust()
	else: g.sfx.line("c_cbtrip" if false else "land", 0.0, true); g.hud.say("系统", "反推未工作：着陆冲击很大！", 4.0); g.shake = 0.05
	g.sfx.line("l1", 3.0); g.sfx.line("l2", 2.0)
	var delay := 30.0 if (g.console.pw("BCN") or g.console.pw("VHF")) else 75.0
	if delay > 30.0: g._later(15.0, func(): g.sfx.line("c_bcn"))
	_helis(); g._later(2.5, func(): g.sfx.line("rescue")); g._later(delay, func(): g.sfx.line("rescue2"); g.sfx.line("home", 1.0); g.hud.objective.text = "搜救队打开了舱门。欢迎回家！")
	g._later(delay + 8.0, func(): _end("任务完成", "启航号安全着陆。最大过载 %.1f g，着陆点距发射场 %.0f 公里。" % [gmax, Vector2(land_pos.x, land_pos.z).length() / 1000.0]))

func _dust() -> void:
	var p := GPUParticles3D.new(); p.amount = 120; p.lifetime = 5.0; p.one_shot = true; p.explosiveness = 0.95
	var pm := ParticleProcessMaterial.new(); pm.direction = Vector3(0, 0.2, 0); pm.spread = 90.0; pm.initial_velocity_min = 8.0; pm.initial_velocity_max = 20.0; pm.damping_min = 4.0; pm.damping_max = 6.0
	pm.scale_min = 2.0; pm.scale_max = 5.0; p.process_material = pm
	var q := QuadMesh.new(); var m := StandardMaterial3D.new(); m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES; m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.75, 0.62, 0.45, 0.6); m.albedo_texture = U.puff_tex(); q.material = m; p.draw_pass_1 = q; add_child(p); p.global_position = g.rocket.global_position; p.emitting = true

func _helis() -> void:
	for i in 2:
		var h := Node3D.new(); g.add_child(h)
		var body := U.mat(Color(0.9, 0.9, 0.88) if i == 0 else Color(0.8, 0.2, 0.15), 0.5, 0.3)
		U.rbox(h, Vector3(2.2, 2.0, 7.0), 0.6, Vector3.ZERO, body); U.box(h, Vector3(0.5, 0.6, 6.0), Vector3(0, 0.4, 5.5), body)
		var rot := Node3D.new(); rot.position = Vector3(0, 1.3, 0); h.add_child(rot); h.set_meta("rot", rot)
		for k in 4: U.box(rot, Vector3(0.35, 0.05, 7.5), Vector3.ZERO, U.mat(Color(0.15, 0.15, 0.15), 0.6), Vector3(0, PI * 0.25 * k, 0))
		h.set_meta("from", Vector3(-800 + i * 300, 160, -1500)); h.set_meta("to", Vector3(30 + i * 25, 1.2, 40 - i * 60))
		heli.append(h)

func _fade_black() -> void:
	g.hud.say("", "", 0.1); var r := ColorRect.new(); r.name = "Black"; r.color = Color(0, 0, 0, 0); r.set_anchors_preset(Control.PRESET_FULL_RECT); r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cl := CanvasLayer.new(); cl.layer = 30; cl.name = "BlackL"; add_child(cl); cl.add_child(r); create_tween().tween_property(r, "color:a", 1.0, 1.0)

func _fade_in() -> void:
	if has_node("BlackL"): var r: ColorRect = get_node("BlackL/Black"); var tw := create_tween(); tw.tween_property(r, "color:a", 0.0, 1.0); tw.tween_callback(get_node("BlackL").queue_free)

func _end(title: String, text: String, bad := false) -> void:
	if endcard: return
	endcard = CanvasLayer.new(); endcard.layer = 45; add_child(endcard)
	var bg := ColorRect.new(); bg.color = Color(0, 0.02, 0.05, 0.86); bg.set_anchors_preset(Control.PRESET_FULL_RECT); endcard.add_child(bg)
	var v := VBoxContainer.new(); v.set_anchors_preset(Control.PRESET_CENTER); v.position = Vector2(-360, -180); v.custom_minimum_size = Vector2(720, 360); endcard.add_child(v)
	var l := Label.new(); l.text = title; l.add_theme_font_size_override("font_size", 52); l.add_theme_color_override("font_color", Color(1, 0.45, 0.35) if bad else Color(1, 1, 1)); l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; v.add_child(l)
	var d := Label.new(); d.text = text + "\n任务时间 " + Hud.fmt_t(g.T); d.add_theme_font_size_override("font_size", 20); d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; v.add_child(d)
	var b := Button.new(); b.text = "再来一次"; b.custom_minimum_size = Vector2(260, 64); b.add_theme_font_size_override("font_size", 24); b.pressed.connect(func(): get_tree().reload_current_scene()); v.add_child(b)

# ---------------- tick ----------------
func tick(dt: float) -> void:
	_disaster_tick()
	if abort_window > 0.0:
		abort_window -= dt
		if abort_window <= 0.0: _crew_loss()
	match phase:
		"deorbit": _deorbit_tick(dt)
		"entry", "abort": _flight_tick(dt)
		"landed":
			landed_t += dt
			for h in heli:
				var f: Vector3 = h.get_meta("from"); var to: Vector3 = h.get_meta("to"); var u := clampf(landed_t / 25.0, 0.0, 1.0)
				var wp: Vector3 = g.site.to_global(land_pos - Vector3(0, Pad.DECK + g.rocket.y_cap, 0)) + f.lerp(to, smoothstep(0.0, 1.0, u)) - Vector3(0, 0, 0)
				h.global_position = wp; (h.get_meta("rot") as Node3D).rotate_y(dt * (30.0 if u < 1.0 else 12.0))

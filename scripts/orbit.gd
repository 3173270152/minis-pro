## Orbit phase: circular orbit with Earth turning below and day/night, orbital module, zero-g float, rendezvous & docking
## with a Tiangong-style station (gated by the console), station interior, EVA, then hand-over to the return ("deorbit").
extends Node3D

const H_ORB := 390000.0
var g
var active := false
var phi := 0.0
var t_orb := 0.0
var om: Node3D              # orbital module (above the descent module)
var station: Node3D
var st_d := 400.0           # range to the station docking port (m)
var st_rate := 0.0          # closing rate (m/s, negative = closing)
var st_lat := Vector2(1.5, -0.8)
var st_latv := Vector2.ZERO
var mode := "seated"        # seated / float / rdv / docked / station / eva
var manual := false
var hatch_open := false
var fp := Vector3.ZERO      # float position (rocket local)
var fv := Vector3.ZERO
var fyaw := 0.0
var fpitch := 0.0
var pad_in
var ui: CanvasLayer
var btns := {}
var status: Label
var said := {}
var eva_pos := Vector3.ZERO
var _fade: ColorRect

func setup(game) -> void:
	g = game
	g.phase_changed.connect(_on_phase)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--orbit="): g._later(0.5, func(): _debug(a.substr(8)))

func _debug(m: String) -> void:
	if not active: _start()
	match m:
		"float": _unbuckle()
		"rdv", "dock": _skip_to_rdv(); if m == "dock": st_d = 3.0
		"station": _skip_to_rdv(); st_d = 0.0; _docked(); g.console.push("HOOKS"); g.console.set_switch("EQV", true); _open_hatch(); _unbuckle(); fp = Vector3(0, g.rocket.y_cap + 6.0, 0)
		"eva": _debug("station"); _eva()

func _on_phase(p: String) -> void:
	if p == "orbit" and not active: _start()

func _start() -> void:
	active = true
	g.cam_mode = "seat"
	if g.rocket.stage2.get_parent() == g.rocket: g._detach(g.rocket.stage2, Vector3(0, -1.5, 0))
	var st: Dictionary = g.flight.state if g.flight else {"pos": Vector3(1.5e6, 0, 0)}
	phi = atan2(st.pos.x, st.pos.y + Earth.R)
	_build_om(); _build_ui()
	g.sfx.line("welcome", 2.0); g.sfx.line("o1", 4.0); g.sfx.line("o2", 1.0); g.sfx.line("o3", 1.0)
	g.hud.objective.text = "在轨飞行。可以解开安全带漂浮，或者开始交会对接（按检查单打开交会雷达和对接机构）"
	g.console.in_space = true

# ---------------- orbital module ----------------
func _build_om() -> void:
	om = Node3D.new(); om.position = Vector3(0, g.rocket.y_cap + 2.25, 0); g.rocket.add_child(om)
	var shell := U.mat(Color(0.86, 0.86, 0.82), 0.7, 0.05, 1.5); shell.cull_mode = BaseMaterial3D.CULL_DISABLED
	var prof := PackedVector2Array([Vector2(0.45, 0.0), Vector2(1.0, 0.3), Vector2(1.12, 1.0), Vector2(1.1, 1.9), Vector2(0.85, 2.5), Vector2(0.45, 2.75)])
	U.put(om, U.lathe(prof, 48, 0.0, TAU, true), U.shader_mat("res://shaders/quilt.gdshader", {"nz": U.noise_tex(0.03, false, 61, 256, 4)}))
	var outer := PackedVector2Array()
	for p in prof: outer.append(p + Vector2(0.08, 0))
	U.put(om, U.lathe(outer, 48), shell)
	# docking mechanism & tunnel on top
	U.cyl(om, 0.42, 0.42, 0.5, Vector3(0, 3.0, 0), U.mat(Color(0.7, 0.72, 0.75), 0.4, 0.8), 24)
	U.cyl(om, 0.55, 0.55, 0.08, Vector3(0, 3.25, 0), U.mat(Color(0.55, 0.55, 0.58), 0.4, 0.8), 24)
	var probe := U.cyl(om, 0.05, 0.08, 0.6, Vector3(0, 3.55, 0), U.mat(Color(0.8, 0.8, 0.82), 0.3, 0.9), 12); om.set_meta("probe", probe)
	# interior: sleeping bag, stowage, handrails, window, toilet, food warmer, lights
	U.rbox(om, Vector3(0.6, 1.6, 0.18), 0.08, Vector3(0.85, 1.3, 0.3), U.mat(Color(0.22, 0.35, 0.62), 0.9), Vector3(0, -0.35, 0))
	for k in 5:
		var a := TAU * k / 5.0
		U.rbox(om, Vector3(0.32, 0.28, 0.16), 0.05, Vector3(sin(a) * 0.95, 1.0 + (k % 2) * 0.6, cos(a) * 0.95), U.mat(Color(0.6, 0.6, 0.52), 0.95))
	for k in 4:
		var a := TAU * k / 4.0 + 0.4
		U.beam(om, Vector3(sin(a) * 1.0, 0.6, cos(a) * 1.0), Vector3(sin(a) * 1.0, 2.1, cos(a) * 1.0), 0.012, U.mat(Color(0.85, 0.55, 0.12), 0.4, 0.6))
	U.cyl(om, 0.16, 0.16, 0.03, Vector3(-1.08, 1.5, 0), U.glass(), 24, Vector3(0, 0, PI * 0.5))
	U.rbox(om, Vector3(0.4, 0.5, 0.4), 0.08, Vector3(-0.7, 0.55, -0.55), U.mat(Color(0.8, 0.8, 0.78), 0.5, 0.3))
	var l := OmniLight3D.new(); l.position = Vector3(0, 1.8, 0); l.omni_range = 3.5; l.light_energy = 1.0; om.add_child(l)
	# solar arrays on the service module (deploy with SA)
	for s in [-1, 1]:
		var w := Node3D.new(); w.position = Vector3(s * 1.4, -3.0, 0); g.rocket.add_child(w); w.set_meta("sa", true)
		var cell := U.mat(Color(0.08, 0.1, 0.22), 0.25, 0.6, 0.5)
		for k in 4: U.box(w, Vector3(1.9, 0.03, 2.0), Vector3(s * (1.1 + k * 2.0), 0, 0), cell)
		w.scale = Vector3(0.05, 1, 1); sa_nodes.append(w)

var sa_nodes: Array = []

# ---------------- station ----------------
func _build_station() -> void:
	station = Node3D.new(); g.add_child(station)
	var white := U.mat(Color(0.9, 0.9, 0.88), 0.55, 0.1, 1.5)
	var mli := U.mat(Color(0.85, 0.82, 0.72), 0.75, 0.2, 2.5)
	var gold := U.mat(Color(0.8, 0.62, 0.25), 0.3, 0.9, 1.0)
	var cell := U.mat(Color(0.12, 0.14, 0.3), 0.25, 0.7, 0.6)
	var rad := U.mat(Color(0.95, 0.95, 0.95), 0.4, 0.1)
	var root := Node3D.new(); station.add_child(root); station.set_meta("root", root)
	# node (docking hub) sphere at the origin, forward port toward -Y (facing the approaching ship)
	U.sphere(root, 1.4, Vector3.ZERO, mli, 32)
	U.cyl(root, 0.55, 0.55, 0.6, Vector3(0, -1.6, 0), U.mat(Color(0.7, 0.72, 0.75), 0.4, 0.8), 24)
	U.cyl(root, 0.7, 0.7, 0.08, Vector3(0, -1.9, 0), gold, 24)
	# Tianhe core: small cabin + large cabin + service section
	U.cyl(root, 1.4, 1.4, 4.0, Vector3(0, 3.2, 0), mli, 48); U.cyl(root, 2.1, 2.1, 7.0, Vector3(0, 8.7, 0), white, 48)
	U.cyl(root, 2.1, 1.6, 3.0, Vector3(0, 13.7, 0), mli, 48)
	for s in [-1, 1]:   # core solar wings
		var w := Node3D.new(); w.position = Vector3(s * 2.2, 10.0, 0); root.add_child(w)
		U.beam(w, Vector3.ZERO, Vector3(s * 12.0, 0, 0), 0.06, white)
		for k in 10: U.box(w, Vector3(1.6, 0.02, 2.8), Vector3(s * (2.0 + k * 1.05), 0, 0), cell)
	U.box(root, Vector3(0.05, 3.2, 6.0), Vector3(0, 12.0, 2.6), rad)
	# Tianzhou cargo ship docked aft
	U.cyl(root, 1.7, 1.7, 9.0, Vector3(0, 19.8, 0), white, 32)
	for s in [-1, 1]: for k in 3: U.box(root, Vector3(2.0, 0.02, 2.4), Vector3(s * (3.0 + k * 2.1), 19.0, 0), cell)
	# Wentian (+X) and Mengtian (-X) labs on the node's lateral ports, with big flexible solar wings
	for s in [-1, 1]:
		var lab := Node3D.new(); lab.position = Vector3(s * 1.4, 0, 0); lab.rotation.z = -s * PI * 0.5; root.add_child(lab)
		U.cyl(lab, 2.1, 2.1, 14.0, Vector3(0, 8.4, 0), white, 48); U.cyl(lab, 1.4, 2.1, 2.0, Vector3(0, 0.6, 0), mli, 48)
		U.cyl(lab, 2.1, 1.8, 2.5, Vector3(0, 16.6, 0), mli, 48)
		for side in [-1, 1]:
			var wing := Node3D.new(); wing.position = Vector3(0, 15.5, side * 2.2); lab.add_child(wing)
			U.beam(wing, Vector3.ZERO, Vector3(0, 0, side * 28.0), 0.07, white)
			for k in 2: U.box(wing, Vector3(4.2, 0.02, 25.0), Vector3((k - 0.5) * 4.4, 0, side * 15.0), cell)
		if s > 0:   # airlock + robotic arm on Wentian
			U.cyl(lab, 0.7, 0.7, 0.3, Vector3(2.15, 3.0, 0), gold, 24, Vector3(0, 0, PI * 0.5))
			U.beam(lab, Vector3(2.1, 5.0, 0), Vector3(3.8, 9.0, 1.0), 0.15, white); U.beam(lab, Vector3(3.8, 9.0, 1.0), Vector3(2.2, 13.0, 0.5), 0.15, white)
	for p in [Vector3(1.2, 4.0, 1.0), Vector3(-1.5, 9.0, -1.8), Vector3(2.2, -0.5, 0.5)]:
		U.sphere(root, 0.08, p, U.emissive(Color(1, 0.2, 0.15), 6.0), 8)
	# interior of the node + core small cabin (enterable)
	var lin := U.shader_mat("res://shaders/quilt.gdshader", {"nz": U.noise_tex(0.03, false, 62, 256, 4), "base": Color(0.88, 0.88, 0.86)})
	var inner := U.lathe(PackedVector2Array([Vector2(0.5, -1.85), Vector2(1.2, -1.0), Vector2(1.32, 0.0), Vector2(1.25, 1.0), Vector2(1.3, 1.3), Vector2(1.3, 5.0), Vector2(1.95, 5.3), Vector2(1.95, 12.0)]), 48, 0.0, TAU, true)
	U.put(root, inner, lin)
	var rack := U.mat(Color(0.82, 0.83, 0.85), 0.5, 0.2, 1.0)
	for y in [6.5, 8.5, 10.5]:
		for k in 4:
			var a := TAU * k / 4.0 + PI * 0.25
			U.box(root, Vector3(1.2, 1.6, 0.25), Vector3(sin(a) * 1.75, y, cos(a) * 1.75), rack, Vector3(0, a, 0))
	U.rbox(root, Vector3(0.6, 0.4, 0.5), 0.05, Vector3(0.9, 9.5, -0.6), U.mat(Color(0.2, 0.2, 0.22), 0.4, 0.5))   # exercise bike-ish unit
	U.box(root, Vector3(0.45, 0.02, 0.3), Vector3(-0.6, 8.0, 1.2), U.emissive(Color(0.3, 0.6, 0.9), 1.5))       # laptop screen
	for y in [2.0, 7.0, 10.0]:
		var l := OmniLight3D.new(); l.position = Vector3(0, y, 0); l.omni_range = 5.0; l.light_energy = 1.1; root.add_child(l)
	station.visible = false

# ---------------- UI ----------------
func _build_ui() -> void:
	ui = CanvasLayer.new(); ui.layer = 13; add_child(ui)
	pad_in = load("res://scripts/touchpad.gd").new(); pad_in.set_anchors_preset(Control.PRESET_FULL_RECT); pad_in.mouse_filter = Control.MOUSE_FILTER_IGNORE; pad_in.visible = false; ui.add_child(pad_in)
	var box := VBoxContainer.new(); box.set_anchors_preset(Control.PRESET_CENTER_LEFT); box.position = Vector2(24, -120); ui.add_child(box)
	for k in [["belt", "解开安全带"], ["rdv", "交会对接（跳过 3 小时）"], ["manual", "手动遥操作"], ["seat", "回到座椅"], ["eva", "出舱活动"], ["home", "返回地球"]]:
		var b := Button.new(); b.text = k[1]; b.custom_minimum_size = Vector2(230, 54); b.add_theme_font_size_override("font_size", 18); b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func(): _btn(k[0])); box.add_child(b); btns[k[0]] = b
	var mv := HBoxContainer.new(); mv.set_anchors_preset(Control.PRESET_BOTTOM_LEFT); mv.position = Vector2(24, -260); ui.add_child(mv)
	for k in [["up", "上浮"], ["dn", "下沉"], ["fwd", "接近"], ["back", "后退"]]:
		var b := Button.new(); b.text = k[1]; b.custom_minimum_size = Vector2(90, 54); b.focus_mode = Control.FOCUS_NONE; b.add_theme_font_size_override("font_size", 16)
		b.button_down.connect(func(): set_meta("hold_" + k[0], true)); b.button_up.connect(func(): set_meta("hold_" + k[0], false)); mv.add_child(b); btns[k[0]] = b
	status = Label.new(); status.set_anchors_preset(Control.PRESET_CENTER_TOP); status.position = Vector2(-300, 96); status.size = Vector2(600, 60)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; status.add_theme_font_size_override("font_size", 20); status.add_theme_color_override("font_color", Color(0.6, 1.0, 0.75)); ui.add_child(status)
	_fade = ColorRect.new(); _fade.color = Color(0, 0, 0, 0); _fade.set_anchors_preset(Control.PRESET_FULL_RECT); _fade.mouse_filter = Control.MOUSE_FILTER_IGNORE; ui.add_child(_fade)

func _hold(k: String) -> bool: return bool(get_meta("hold_" + k, false))

func _btn(k: String) -> void:
	match k:
		"belt": _unbuckle()
		"seat":
			if mode == "eva": mode = "station"; fp = Vector3(0, g.rocket.y_cap + 8.0, 0); g.set_phase("docked"); return
			mode = "seated"; g.cam_mode = "seat"; pad_in.visible = false
		"rdv": _skip_to_rdv()
		"manual": manual = not manual; g.hud.say("系统", "手动遥操作：" + ("开（接近/后退按钮、拖动修正横向）" if manual else "关（自动逼近）"), 3.0)
		"eva": _eva()
		"home": _go_home()

func _unbuckle() -> void:
	mode = "float"; g.cam_mode = "module"; pad_in.visible = true
	fp = g.capsule.EYE + Vector3(0, g.rocket.y_cap, 0); fv = Vector3.ZERO
	g.sfx.line("float", 0.5); g.hud.objective.text = "失重漂浮：左下摇杆移动，右侧拖动环视，上浮/下沉按钮。舱门上方是轨道舱"

func _skip_to_rdv() -> void:
	if station == null: _build_station()
	var tw := create_tween(); tw.tween_property(_fade, "color:a", 1.0, 0.7)
	tw.tween_callback(func():
		station.visible = true; st_d = 400.0; st_rate = -0.6; mode = "rdv" if mode == "seated" else mode; g.set_phase("rdv")
		t_orb += 3.0 * 3600.0; g.T += 3.0 * 3600.0
		g.sfx.line("rdv400", 0.5); g.hud.objective.text = "交会对接：自动逼近中（需要交会雷达、制导计算机和姿控）。接触速度必须小于 0.35 m/s")
	tw.tween_property(_fade, "color:a", 0.0, 0.7)

func _docked() -> void:
	mode = "docked" if mode == "rdv" else mode; g.set_phase("docked")
	g.sfx.line("dock", 0.0, true); g.sfx.line("dockme", 2.0); g.sfx.line("sthi", 6.0)
	g.hud.objective.text = "捕获成功！按检查单：闭合对接锁（HOOKS）→ 打开均压阀（EQV）→ 压差归零后舱门打开"

func _open_hatch() -> void:
	hatch_open = true; g.sfx.line("leak", 0.5); g.hud.objective.text = "舱门打开。解开安全带，向上穿过轨道舱和对接通道，飘进天和核心舱"
	g.console.hatch_closed = true

func _eva() -> void:
	if station == null or not hatch_open: g.hud.say("系统", "需要先进入空间站，从节点舱出舱", 3.0); return
	var tw := create_tween(); tw.tween_property(_fade, "color:a", 1.0, 0.8)
	tw.tween_callback(func(): mode = "eva"; g.set_phase("eva"); eva_pos = Vector3(2.0, -0.5, 0.0); fv = Vector3.ZERO; g.sfx.line("evaopen", 0.5); g.hud.objective.text = "出舱活动：穿着舱外航天服，安全绳挂在扶手上。慢慢移动，别离开空间站太远")
	tw.tween_property(_fade, "color:a", 0.0, 1.2)

func _go_home() -> void:
	var tw := create_tween(); tw.tween_property(_fade, "color:a", 1.0, 1.0)
	tw.tween_callback(func():
		mode = "seated"; g.cam_mode = "seat"; pad_in.visible = false; hatch_open = false
		if station: station.visible = false
		ui.visible = false; active = false; g.hud.objective.text = "返回准备：火工品预位、轨控发动机预位、离轨程序（见程序手册「返回准备」）"
		g.sfx.line("retprep", 0.5); g.sfx.line("undock", 3.0); g.set_phase("deorbit"))
	tw.tween_property(_fade, "color:a", 0.0, 1.0)

func _unhandled_input(e: InputEvent) -> void:
	if active and pad_in.visible: pad_in.feed(e)

# ---------------- tick ----------------
func tick(dt: float) -> void:
	if not active: return
	t_orb += dt
	var r := Earth.R + H_ORB; var w := sqrt(Flight.MU / (r * r * r))
	phi += w * dt
	var p := Vector3(sin(phi) * r, cos(phi) * r - Earth.R, 0.0)
	g.site.position = -p
	g.alt = H_ORB; g.vel = w * r; g.gload = 0.0; g.qdyn = 0.0
	# attitude: vehicle axis along the velocity (nose = docking port forward)
	var fwd := Vector3(cos(phi), -sin(phi), 0.0)
	g.rocket.transform = Transform3D(U.basis_from_y(fwd), Vector3(0, Pad.DECK, 0))
	# day/night: the sun direction is fixed in inertial space, so it sweeps around once per orbit
	g.world.sun.global_transform = Transform3D(Basis.looking_at(-Vector3(cos(t_orb * w * -1.0 + 0.5), sin(t_orb * w * -1.0 + 0.5), 0.25).normalized(), Vector3(0, 0, 1)), Vector3.ZERO)
	g._update_sun()
	g.world.terrain.visible = false; g.pad.visible = false; g.earth.set_fade(1.0)
	g.world.sky_mat.energy_multiplier = 0.02; g.world.env.fog_enabled = false
	# solar arrays
	for wn: Node3D in sa_nodes:
		wn.scale.x = lerpf(wn.scale.x, 1.0 if g.console.step_push_done("SA") else 0.05, minf(1.0, dt * 0.4))
	if om.has_meta("probe"): (om.get_meta("probe") as Node3D).scale.y = 1.0 if g.console.pw("PROBE") else 0.3
	btns.rdv.visible = station == null or not station.visible
	btns.manual.visible = mode == "rdv" or (station != null and station.visible and not hatch_open)
	btns.eva.visible = hatch_open and mode != "eva"
	btns.seat.visible = mode in ["float", "station", "eva"]; btns.seat.text = "返回舱内" if mode == "eva" else "回到座椅"
	btns.belt.visible = mode == "seated" or mode == "docked"
	for k in ["up", "dn"]: btns[k].visible = mode in ["float", "station", "eva"]
	for k in ["fwd", "back"]: btns[k].visible = manual and station != null and st_d > 0.0
	if station and station.visible: _rdv(dt)
	if mode in ["float", "station"]: _float(dt)
	elif mode == "eva": _eva_tick(dt)

func _rdv(dt: float) -> void:
	var c = g.console
	var root: Node3D = station.get_meta("root")
	# station sits ahead along the docking axis; the ship's docking port is at om top (rocket local y = Y_CAPSULE + 2.25 + 3.3)
	var port_local := Vector3(0, g.rocket.y_cap + 2.25 + 3.3, 0)
	var port_g: Vector3 = g.rocket.to_global(port_local)
	var axis: Vector3 = g.rocket.global_transform.basis.y
	var side: Vector3 = g.rocket.global_transform.basis.x; var up2: Vector3 = g.rocket.global_transform.basis.z
	if st_d > 0.0:
		var auto_ok: bool = c.pw("DKRAD") and c.gnc_n() > 0 and c.rcs_k() > 0.0
		var k: float = c.rcs_k()
		if manual:
			if _hold("fwd"): st_rate -= 0.05 * k * dt
			if _hold("back"): st_rate += 0.05 * k * dt
			st_latv += Vector2(-pad_in.vec.x, pad_in.vec.y) * 0.03 * k * dt
		elif auto_ok:
			var tgt := -5.0 if st_d > 200.0 else (-1.5 if st_d > 30.0 else -clampf(st_d * 0.02, 0.12, 0.3))
			st_rate += clampf(tgt - st_rate, -0.4 * dt, 0.4 * dt); st_latv += (-st_lat * 0.04 - st_latv * 0.5) * dt
		else:
			st_rate *= 1.0 - minf(1.0, dt * 0.1)
			if not said.has("stall"): said["stall"] = true; g.sfx.line("c_rdvst" if not c.pw("DKRAD") else "c_rcs")
		st_d += st_rate * dt; st_lat += st_latv * dt
		if st_d <= 0.0:
			if not c.pw("PROBE"): st_d = 0.8; st_rate = 0.12; g.sfx.line("c_probe", 0.0, true)
			elif absf(st_rate) < 0.36 and st_lat.length() < 0.35: st_d = 0.0; st_rate = 0.0; st_lat = Vector2.ZERO; _docked()
			else: st_d = 1.0; st_rate = 0.25; g.hud.say("系统", "接触速度过大，弹开！（%.2f m/s）" % absf(st_rate), 3.0)
		status.text = "距离 %.1f m   接近速度 %.2f m/s   横向偏差 %.2f m" % [st_d, -st_rate, st_lat.length()]
	else:
		status.text = "已对接 · 压差 %.1f kPa" % absf(c.cabP - c.vestP)
		if not hatch_open and c.hooks and absf(c.cabP - c.vestP) < 0.4 and c.cabP > 80.0: _open_hatch()
	# place the station: its forward port (local -Y*1.9) faces our port
	station.global_transform = Transform3D(U.basis_from_y(axis), port_g + axis * (st_d + 1.9) + side * st_lat.x + up2 * st_lat.y)

func _float(dt: float) -> void:
	var cam: Camera3D = g.cam
	fyaw -= pad_in.look.x * 0.004; fpitch = clampf(fpitch - pad_in.look.y * 0.004, -1.4, 1.4); pad_in.look = Vector2.ZERO
	var b: Basis = g.rocket.global_transform.basis * Basis(Vector3(0, 0, 1), PI * 0.5) * Basis(Vector3.UP, fyaw) * Basis(Vector3.RIGHT, fpitch)
	var mv: Vector2 = pad_in.vec
	var k := Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S)))
	if k.length() > 0.0: mv = k.normalized()
	var upv := float(_hold("up") or Input.is_physical_key_pressed(KEY_SPACE)) - float(_hold("dn") or Input.is_physical_key_pressed(KEY_C))
	var acc_w: Vector3 = (-b.z * mv.y + b.x * mv.x + b.y * upv) * 1.2
	var acc: Vector3 = g.rocket.global_transform.basis.inverse() * acc_w
	fv += acc * dt; fv *= 1.0 - minf(1.0, dt * 1.2)
	var np := fp + fv * dt
	# allowed volume: descent module, orbital module, tunnel and (when the hatch is open) the station interior
	var y: float = np.y - float(g.rocket.y_cap); var rr: float = Vector2(np.x, np.z).length()
	var lim := 0.0
	if y < 2.1: lim = g.capsule.inner_r(clampf(y, 0.05, 2.15)) - 0.25
	elif y < 4.9: lim = 0.85
	elif y < 5.9: lim = 0.3 if not hatch_open else 0.4
	elif hatch_open and y < 22.0: lim = 1.0 if y < 11.0 else 1.6
	else: lim = -1.0
	if y < 0.25 or lim < 0.0 or rr > lim:
		fv *= -0.3; np = fp
	fp = np
	mode = "station" if y > 6.0 else ("float" if mode == "station" else mode)
	cam.global_transform = Transform3D(b, g.rocket.to_global(fp))
	cam.fov = lerpf(cam.fov, 74.0 / g.zoom, 0.2)

func _eva_tick(dt: float) -> void:
	var cam: Camera3D = g.cam; var root: Node3D = station.get_meta("root")
	fyaw -= pad_in.look.x * 0.004; fpitch = clampf(fpitch - pad_in.look.y * 0.004, -1.4, 1.4); pad_in.look = Vector2.ZERO
	var b: Basis = root.global_transform.basis * Basis(Vector3.UP, fyaw) * Basis(Vector3.RIGHT, fpitch)
	var mv: Vector2 = pad_in.vec
	var upv := float(_hold("up")) - float(_hold("dn"))
	fv += (-b.z * mv.y + b.x * mv.x + b.y * upv) * 0.4 * dt; fv *= 1.0 - minf(1.0, dt * 0.6)
	var wp := root.to_global(eva_pos) + fv * dt
	eva_pos = root.to_local(wp)
	if eva_pos.length() > 26.0: eva_pos = eva_pos.normalized() * 26.0; fv *= -0.2   # tether
	cam.global_transform = Transform3D(b, root.to_global(eva_pos))
	status.text = "舱外活动 · 安全绳 %.1f m / 26 m" % eva_pos.length()

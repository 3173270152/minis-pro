## Launch day on foot: crew building lobby -> bus ride along the road -> tower elevator -> crew access arm -> white room
## -> through the hatch -> tap your seat. First-person CharacterBody3D (Jolt), left-thumb joystick / WASD, drag to look.
extends Node3D

const TB := Vector3(150, 0, 1290)        # crew building (site frame), entrance faces -x toward the road
const ROAD_X := 60.0
var g
var active := false
var stage := "lobby"
var body: CharacterBody3D
var pad_in                       # touchpad
var yaw := PI * 0.5
var pitch := 0.0
var bus: Node3D
var bus_t := 0.0
var bus_path: Curve3D
var npcs: Array = []
var trail: Array = []
var prompt: Label
var act_btn: Button
var target := Vector3.ZERO
var marker: MeshInstance3D
var elev_t := -1.0
var said := {}
var bob := 0.0
var _fade: ColorRect
var crowd: MultiMeshInstance3D

func setup(game) -> void:
	g = game
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--view=") or a.begins_with("--flight=") or a.begins_with("--T=") or a == "--powered": return
	if g.cfg.mode == "spectator" or g.cfg.get("skip_walk", false): return
	active = true
	g.set_phase("crew"); g.cam_mode = "module"; g.T = -9000.0; g.hud.proc_box.visible = false
	for c in g.capsule.crew: c.visible = false
	_build_terminal(); _build_bus(); _build_player(); _build_ui()
	for i in 2: npcs.append(_astronaut(Color(0.2, 0.35, 0.75) if i == 0 else Color(0.75, 0.15, 0.12)))
	for a in args:
		if a.begins_with("--crew="): _jump(a.substr(7))
	g.hud.objective.text = "问天阁 · 出征仪式。走出大门，登上去发射场的大巴（左下摇杆移动，拖动右侧环视）"
	g.sfx.line("t1", 2.0); g.sfx.line("t2", 1.0); g.sfx.line("t3", 0.8); g.sfx.line("t6", 3.0)
	_set_target(TB + Vector3(-22, 0, 0))

# ---------------- world ----------------
func _build_terminal() -> void:
	var t := Node3D.new(); t.position = TB; g.site.add_child(t)
	var wall := U.tri_mat(Color(0.86, 0.85, 0.82), 0.7, 0.05, 0.4, 1.0)
	var floor_m := U.mat(Color(0.75, 0.72, 0.68), 0.25, 0.1, 0.6)
	var glass := U.glass()
	U.box(t, Vector3(40, 0.2, 30), Vector3(0, 0.1, 0), floor_m)
	U.box(t, Vector3(40, 0.4, 30), Vector3(0, 9.0, 0), wall)
	U.box(t, Vector3(0.4, 9, 30), Vector3(20, 4.5, 0), wall)
	for s in [-1, 1]: U.box(t, Vector3(40, 9, 0.4), Vector3(0, 4.5, s * 15), wall)
	# glazed front facade with mullions and the entrance gap
	for z in range(-14, 15, 2):
		U.box(t, Vector3(0.15, 9, 0.12), Vector3(-20, 4.5, z), U.mat(Color(0.3, 0.32, 0.35), 0.4, 0.8))
	U.box(t, Vector3(0.05, 9, 11), Vector3(-20, 4.5, -8.5), glass); U.box(t, Vector3(0.05, 9, 11), Vector3(-20, 4.5, 8.5), glass)
	U.box(t, Vector3(0.05, 3, 6), Vector3(-20, 7.5, 0), glass)
	U.box(t, Vector3(6, 0.3, 8), Vector3(-23, 4.0, 0), wall)      # entrance canopy
	for z in [-3.5, 3.5]: U.cyl(t, 0.25, 0.25, 4.0, Vector3(-25.5, 2.0, z), wall, 12)
	# lobby: farewell banner, flags, columns, ceiling lights, signing wall, coffee counter, screen
	var red := U.mat(Color(0.72, 0.08, 0.06), 0.7)
	U.box(t, Vector3(0.1, 2.0, 12), Vector3(19.7, 6.0, 0), red)
	var l := U.label(t, "出征 · 启航号载人飞行任务", Vector3(19.6, 6.0, 0), 1.1, Color(1.0, 0.85, 0.3), Vector3(0, -PI * 0.5, 0))
	for z in range(-10, 11, 5):
		U.cyl(t, 0.35, 0.35, 8.8, Vector3(0, 4.5, z), U.mat(Color(0.92, 0.92, 0.9), 0.4, 0.1), 16)
		var lamp := OmniLight3D.new(); lamp.position = Vector3(0, 8.3, z); lamp.omni_range = 12.0; lamp.light_energy = 1.2; lamp.shadow_enabled = false; t.add_child(lamp)
		U.box(t, Vector3(1.2, 0.06, 1.2), Vector3(0, 8.75, z), U.emissive(Color(1, 0.97, 0.9), 2.5))
	U.box(t, Vector3(8, 3, 0.1), Vector3(8, 2.0, 14.7), U.mat(Color(0.95, 0.95, 0.93), 0.6))
	U.label(t, "签名墙", Vector3(8, 3.8, 14.6), 0.5, Color(0.1, 0.1, 0.1), Vector3(0, PI, 0))
	U.box(t, Vector3(4, 1.1, 1.0), Vector3(10, 0.55, -12), U.mat(Color(0.35, 0.22, 0.15), 0.5, 0.1))
	U.cyl(t, 0.25, 0.25, 0.5, Vector3(9, 1.35, -12), U.mat(Color(0.15, 0.15, 0.16), 0.3, 0.8), 12)
	U.box(t, Vector3(0.1, 2.6, 4.6), Vector3(19.7, 2.6, -9), U.emissive(Color(0.25, 0.45, 0.8), 1.0))
	U.label(t, "家人视频连线", Vector3(19.6, 4.2, -9), 0.4, Color(1, 1, 1), Vector3(0, -PI * 0.5, 0))
	for x in [12.0, 16.0]:
		U.cyl(t, 0.04, 0.04, 3.0, Vector3(x, 1.5, 13.5), U.mat(Color(0.7, 0.7, 0.7), 0.3, 0.8), 8)
		U.box(t, Vector3(1.2, 0.8, 0.02), Vector3(x + 0.6, 2.6, 13.5), red)
	# walls as collision
	var sb := StaticBody3D.new(); t.add_child(sb)
	for b in [[Vector3(0.4, 9, 30), Vector3(20, 4.5, 0)], [Vector3(40, 9, 0.4), Vector3(0, 4.5, 15)], [Vector3(40, 9, 0.4), Vector3(0, 4.5, -15)], [Vector3(0.4, 9, 11), Vector3(-20, 4.5, -8.5)], [Vector3(0.4, 9, 11), Vector3(-20, 4.5, 8.5)]]:
		var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = b[0]; cs.shape = bs; cs.position = b[1]; sb.add_child(cs)
	# farewell crowd along the road and in front of the building, waving
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_colors = true
	var cap := CapsuleMesh.new(); cap.radius = 0.24; cap.height = 1.7; cap.radial_segments = 8; cap.rings = 2; mm.mesh = cap
	var pts := []
	for i in 260: pts.append(Vector3(ROAD_X + (8.0 if i % 2 == 0 else -8.0) + randf_range(-1.5, 1.5), 0.85, 1200.0 - i * 2.2 + randf_range(-0.6, 0.6)))
	for i in 140: pts.append(TB + Vector3(-34 + randf_range(-4, 4), 0.85, randf_range(-24, 24) if absf(i - 70.0) > 2.0 else 30.0))
	mm.instance_count = pts.size()
	for i in pts.size():
		mm.set_instance_transform(i, Transform3D(Basis(), pts[i])); mm.set_instance_color(i, Color.from_hsv(randf(), randf_range(0.3, 0.8), randf_range(0.5, 0.95)))
	crowd = MultiMeshInstance3D.new(); crowd.multimesh = mm; var cm := StandardMaterial3D.new(); cm.vertex_color_use_as_albedo = true; cm.roughness = 0.8; crowd.material_override = cm
	g.site.add_child(crowd)

func _build_bus() -> void:
	bus = Node3D.new(); g.site.add_child(bus)
	var white := U.mat(Color(0.93, 0.93, 0.92), 0.35, 0.3, 0.8)
	U.rbox(bus, Vector3(2.5, 2.9, 11.5), 0.25, Vector3(0, 1.85, 0), white)
	U.box(bus, Vector3(2.55, 0.25, 11.6), Vector3(0, 1.05, 0), U.mat(Color(0.12, 0.3, 0.7), 0.4, 0.3))
	var win := U.mat(Color(0.08, 0.1, 0.12), 0.05, 0.9)
	for s in [-1, 1]: U.box(bus, Vector3(0.02, 1.0, 9.5), Vector3(s * 1.26, 2.45, -0.5), win)
	U.box(bus, Vector3(2.3, 1.2, 0.02), Vector3(0, 2.4, -5.76), win)
	for zz in [-3.8, 3.6]:
		for s in [-1, 1]: U.cyl(bus, 0.5, 0.5, 0.35, Vector3(s * 1.15, 0.5, zz), U.mat(Color(0.08, 0.08, 0.08), 0.8), 18, Vector3(0, 0, PI * 0.5))
	var seat := U.mat(Color(0.2, 0.25, 0.4), 0.8)
	for r in 6:
		for s in [-1, 1]: U.rbox(bus, Vector3(0.9, 0.5, 0.5), 0.08, Vector3(s * 0.65, 1.45, -3.0 + r * 1.2), seat)
	var l := OmniLight3D.new(); l.position = Vector3(0, 2.9, 0); l.omni_range = 7.0; l.light_energy = 0.6; bus.add_child(l)
	U.label(bus, "航天员专车", Vector3(1.28, 2.0, 1.5), 0.45, Color(0.12, 0.3, 0.7), Vector3(0, PI * 0.5, 0))
	bus_path = Curve3D.new()
	for p in [Vector3(ROAD_X, 0, TB.z), Vector3(ROAD_X, 0, 900), Vector3(ROAD_X, 0, 300), Vector3(ROAD_X - 6, 0, 70), Vector3(ROAD_X - 22, 0, 34)]: bus_path.add_point(p)
	bus.position = Vector3(ROAD_X, 0, TB.z); bus.rotation.y = 0.0

func _astronaut(trim: Color) -> Node3D:
	var n := Node3D.new(); g.site.add_child(n)
	var suit := U.mat(Color(0.93, 0.93, 0.9), 0.85, 0.0, 1.5); var tm := U.mat(trim, 0.6)
	U.rbox(n, Vector3(0.5, 0.75, 0.32), 0.12, Vector3(0, 1.25, 0), suit)
	U.sphere(n, 0.13, Vector3(0, 1.78, 0), U.mat(Color(0.85, 0.7, 0.58), 0.7), 16)
	U.cyl(n, 0.16, 0.16, 0.05, Vector3(0, 1.64, 0), tm, 16)
	for s in [-1, 1]:
		U.rbox(n, Vector3(0.17, 0.85, 0.18), 0.07, Vector3(s * 0.12, 0.45, 0), suit)
		U.rbox(n, Vector3(0.12, 0.6, 0.12), 0.05, Vector3(s * 0.32, 1.22, 0), suit)
		U.rbox(n, Vector3(0.18, 0.08, 0.28), 0.03, Vector3(s * 0.12, 0.04, 0.04), U.mat(Color(0.2, 0.2, 0.2), 0.8))
	U.box(n, Vector3(0.12, 0.08, 0.01), Vector3(0.12, 1.45, 0.165), U.mat(Color(0.85, 0.1, 0.07), 0.6))
	U.rbox(n, Vector3(0.28, 0.32, 0.2), 0.06, Vector3(0, 1.1, -0.26), U.mat(Color(0.7, 0.7, 0.68), 0.7))   # ventilation case
	n.position = TB + Vector3(-12, 0.1, 2.0 if npcs.size() == 0 else -2.0)
	return n

func _build_player() -> void:
	body = CharacterBody3D.new(); var cs := CollisionShape3D.new(); var sh := CapsuleShape3D.new(); sh.radius = 0.3; sh.height = 1.75; cs.shape = sh; cs.position.y = 0.875
	body.add_child(cs); g.site.add_child(body); body.position = TB + Vector3(-8, 0.2, 0)
	marker = MeshInstance3D.new(); var m := SphereMesh.new(); m.radius = 0.35; m.height = 0.7; marker.mesh = m; marker.material_override = U.emissive(Color(1.0, 0.75, 0.2), 3.0)
	g.site.add_child(marker)

func _build_ui() -> void:
	var cl := CanvasLayer.new(); cl.layer = 12; add_child(cl)
	pad_in = load("res://scripts/touchpad.gd").new(); pad_in.set_anchors_preset(Control.PRESET_FULL_RECT); pad_in.mouse_filter = Control.MOUSE_FILTER_IGNORE; cl.add_child(pad_in)
	prompt = Label.new(); prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM); prompt.position = Vector2(-300, -230); prompt.size = Vector2(600, 40)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; prompt.add_theme_font_size_override("font_size", 24); prompt.add_theme_color_override("font_color", Color(1, 0.85, 0.4)); cl.add_child(prompt)
	act_btn = Button.new(); act_btn.text = "交互"; act_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT); act_btn.position = Vector2(-230, -170); act_btn.custom_minimum_size = Vector2(150, 70)
	act_btn.add_theme_font_size_override("font_size", 24); act_btn.focus_mode = Control.FOCUS_NONE; act_btn.pressed.connect(_interact); act_btn.visible = false; cl.add_child(act_btn)
	_fade = ColorRect.new(); _fade.color = Color(0, 0, 0, 0); _fade.set_anchors_preset(Control.PRESET_FULL_RECT); _fade.mouse_filter = Control.MOUSE_FILTER_IGNORE; cl.add_child(_fade)

func _set_target(p: Vector3) -> void: target = p

func _unhandled_input(e: InputEvent) -> void:
	if not active: return
	pad_in.feed(e)
	if e is InputEventKey and e.pressed and not e.echo and (e.keycode == KEY_E or e.keycode == KEY_SPACE): _interact()

# ---------------- flow ----------------
func _near(p: Vector3, r: float) -> bool: return body.position.distance_to(p) < r

func _interact() -> void:
	match stage:
		"lobby":
			if _near(bus.position + Vector3(-1.4, 0, -4.0), 4.0): _board_bus()
		"walk_pad":
			if _near(_elev_base(), 3.0): _ride_elevator()
		"whiteroom":
			if _near(_hatch_pos(), 2.5): _enter_capsule()
		"cabin":
			_sit()

func _jump(s: String) -> void:
	match s:
		"bus": _board_bus()
		"pad": stage = "walk_pad"; body.position = Vector3(ROAD_X - 24, 0.2, 34); bus.position = bus_path.get_point_position(4)
		"elevator": stage = "walk_pad"; body.position = _elev_base(); _ride_elevator()
		"whiteroom": stage = "whiteroom"; body.position = _hatch_pos() + Vector3(-2, 0.1, 0)
		"cabin": _enter_capsule()

func _board_bus() -> void:
	stage = "bus"; bus_t = 0.0; g.sfx.line("t12", 0.0, true); g.sfx.line("t13", 0.5); g.sfx.line("b1", 3.0)
	for n in npcs: n.visible = false
	g.hud.objective.text = "大巴车驶向发射场。路两边是送行的人群"
	for k in ["b2", "b3", "b4", "b5", "b6", "b7"]: g.sfx.line(k, 2.0)

func _elev_base() -> Vector3: return Vector3(g.pad.TOWER_X - Pad.TOWER_W * 0.5 - 1.6, 0.2, 0)
func _hatch_pos() -> Vector3: return Vector3(g.pad.veh_hatch_x - 0.9, g.pad.arm_y, 0)

func _ride_elevator() -> void:
	stage = "elevator"; elev_t = 0.0; g.sfx.line("w2", 0.5, true); g.hud.objective.text = "电梯上行"

func _enter_capsule() -> void:
	stage = "fade"; var tw := create_tween(); tw.tween_property(_fade, "color:a", 1.0, 0.8)
	tw.tween_callback(func():
		stage = "cabin"; g.hud.objective.text = "进入返回舱：点击中间的指令长座椅坐下"; g.sfx.line("seat1", 0.5)
		body.visible = false)
	tw.tween_property(_fade, "color:a", 0.0, 0.8)

func _sit() -> void:
	stage = "done"; active = false
	for c in g.capsule.crew: c.visible = true
	for n in npcs: n.queue_free()
	if crowd: crowd.visible = false
	prompt.text = ""; act_btn.visible = false; pad_in.visible = false; marker.visible = false
	g.T = -60.0; g.cam_mode = "seat"; g.hud.proc_box.visible = true; g.set_phase("seat")
	g.sfx.line("seat2", 0.5); g.sfx.line("hatch", 3.0)
	g.hud.objective.text = "舱门关闭。任务 1 / 3：按飞行程序手册给飞船加电（不限顺序）。不熟悉可以点「开始指导」或「队友执行」"

func tick(dt: float) -> void:
	if not active: return
	# look
	yaw -= pad_in.look.x * 0.004; pitch = clampf(pitch - pad_in.look.y * 0.004, -1.2, 1.2); pad_in.look = Vector2.ZERO
	var cam: Camera3D = g.cam
	match stage:
		"bus":
			bus_t += dt * 16.0
			var L := bus_path.get_baked_length(); var u := minf(bus_t, L)
			var p := bus_path.sample_baked(u); var p2 := bus_path.sample_baked(minf(u + 2.0, L))
			bus.position = p; if p2.distance_to(p) > 0.1: bus.look_at(g.site.to_global(p2), Vector3.UP)
			cam.global_transform = bus.global_transform * Transform3D(Basis(Vector3.UP, yaw - PI * 0.5) * Basis(Vector3.RIGHT, pitch), Vector3(0.65, 2.25, -1.0))
			if u >= L:
				stage = "walk_pad"; body.position = g.site.to_local(bus.global_transform * Vector3(-2.2, 0.2, -4.0)); g.sfx.line("b8", 0.0, true); g.sfx.line("b9", 1.5)
				g.hud.objective.text = "走到塔架底部的乘员电梯（跟随黄色标记）"; _set_target(_elev_base())
			_ui(); return
		"elevator":
			elev_t += dt
			var h: float = clampf(elev_t / 22.0, 0.0, 1.0) * (g.pad.arm_y - 0.1)
			g.pad.elevator.position.y = 0.1 + h; body.position = _elev_base() + Vector3(0, h, 0); body.velocity = Vector3.ZERO
			if elev_t > 22.5:
				stage = "whiteroom"; g.sfx.line("w3", 0.0, true); g.hud.objective.text = "沿乘员通道臂走进白房间，到舱门口"; _set_target(_hatch_pos())
				body.position = Vector3(g.pad.TOWER_X + Pad.TOWER_W * 0.5 - 0.5, g.pad.arm_y + 0.1, 0)
		"cabin":
			var base: Transform3D = g.capsule.seat_anchor.global_transform
			cam.global_transform = Transform3D(base.basis * Basis(Vector3.UP, yaw * 0.3) * Basis(Vector3.RIGHT, pitch * 0.3), base.origin + base.basis.z * 0.25)
			prompt.text = "点击这里坐下（中间座椅）"; act_btn.visible = true; act_btn.text = "坐下"
			if not pad_in.taps.is_empty(): pad_in.taps.clear(); _sit()
			return
		"fade": return
	# walking (lobby, walk_pad, whiteroom)
	if stage != "elevator":
		var mv: Vector2 = pad_in.vec
		var k := Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)), float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S)))
		if k.length() > 0.0: mv = k.normalized()
		var run := Input.is_physical_key_pressed(KEY_SHIFT) or mv.length() > 0.95
		var fwd := Vector3(-sin(yaw), 0, -cos(yaw)); var right := Vector3(cos(yaw), 0, -sin(yaw))
		var want := (fwd * mv.y + right * mv.x) * (5.5 if run else 3.2)
		body.velocity.x = want.x; body.velocity.z = want.z
		if not body.is_on_floor(): body.velocity.y -= 9.8 * dt
		else: body.velocity.y = -0.5
		body.move_and_slide()
		bob += want.length() * dt * 2.2
		if body.position.y < -5.0: body.position = _elev_base()
	var eye: Vector3 = g.site.to_global(body.position + Vector3(0, 1.65 + sin(bob * 2.0) * 0.03, 0))
	cam.global_transform = Transform3D(Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch), eye)
	cam.fov = 72.0
	# NPC crewmates follow along the player's path
	trail.push_front(body.position)
	if trail.size() > 120: trail.pop_back()
	for i in npcs.size():
		var n: Node3D = npcs[i]; var idx := mini(trail.size() - 1, 40 + i * 30)
		var tp: Vector3 = trail[idx] + Vector3(0, 0, 0.9 * (1 if i == 0 else -1))
		if stage == "lobby" or stage == "walk_pad" or stage == "whiteroom":
			n.visible = true
			if n.position.distance_to(tp) > 0.05: n.look_at(g.site.to_global(Vector3(tp.x, n.position.y, tp.z)) + Vector3(0.001, 0, 0), Vector3.UP); n.rotate_y(PI)
			n.position = n.position.lerp(tp, minf(1.0, dt * 2.0))
	if stage == "walk_pad" and n_visible_jump(): pass
	_ui()

func n_visible_jump() -> bool:
	# crewmates arrive with the bus
	for n in npcs: if not n.visible: n.position = body.position + Vector3(-2, 0, 0)
	return false

func _ui() -> void:
	marker.visible = stage in ["lobby", "walk_pad", "whiteroom"]
	var tgt := target
	if stage == "lobby": tgt = bus.position + Vector3(-1.4, 0, -4.0)
	marker.position = tgt + Vector3(0, 2.4 + sin(Time.get_ticks_msec() * 0.004) * 0.2, 0)
	var p := ""
	match stage:
		"lobby": p = "点击「上车」登上大巴" if _near(tgt, 4.0) else "走出大门，前往大巴车（黄色标记）"
		"walk_pad": p = "点击「乘电梯」上到 %d 米层" % int(g.pad.arm_y) if _near(_elev_base(), 3.0) else "走到乘员电梯（黄色标记）"
		"whiteroom": p = "点击「进舱」从舱门进入飞船" if _near(_hatch_pos(), 2.5) else "沿通道臂走到白房间舱门口"
		"bus": p = "乘车中…"
		"elevator": p = "电梯上行 %d m" % int(body.position.y)
	prompt.text = p
	act_btn.visible = (stage == "lobby" and _near(tgt, 4.0)) or (stage == "walk_pad" and _near(_elev_base(), 3.0)) or (stage == "whiteroom" and _near(_hatch_pos(), 2.5))
	act_btn.text = {"lobby": "上车", "walk_pad": "乘电梯", "whiteroom": "进舱"}.get(stage, "交互")

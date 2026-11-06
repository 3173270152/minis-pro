## Cabin multifunction displays: rendered by 2D viewports at 10 Hz onto capsule.screens.
## Pages: 飞行 FLIGHT (attitude, alt/vel/g/q/mach, trajectory), 任务 MISSION (clock, phase, events, checklist, C&W),
## 系统 SYSTEMS (EPS / ECLSS / PROP / COMM). Unpowered screens are black; power-on shows a self-test boot screen.
## Tap a screen to cycle its page.
extends Node

const W := 640
const H := 400
const PAGES := ["飞行", "任务", "电源", "环控", "推进", "通信"]
var g
var scr: Array = []        # [{vp, canvas, page, boot_t, was_on, mat}]
var acc := 0.0

class Pane extends Control:
	var owner_mfd
	var idx := 0
	func _draw() -> void: owner_mfd.draw_page(self, idx)

func setup(game) -> void:
	g = game
	game.set_meta("mfd", self)
	if g.capsule == null or not ("screens" in g.capsule): return
	var i := 0
	for s in g.capsule.screens:
		var q: MeshInstance3D = s
		var vp := SubViewport.new(); vp.size = Vector2i(W, H); vp.disable_3d = true; vp.transparent_bg = false
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		g.add_child(vp)
		var p := Pane.new(); p.owner_mfd = self; p.idx = i; p.size = Vector2(W, H); vp.add_child(p)
		var m := StandardMaterial3D.new(); m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; m.albedo_texture = vp.get_texture()
		m.emission_enabled = false; m.cull_mode = BaseMaterial3D.CULL_DISABLED; q.material_override = m
		# hit area so a tap cycles the page (main routes ids "MFD<n>")
		var body := StaticBody3D.new(); body.collision_layer = 1 << 10; body.collision_mask = 0
		var cs := CollisionShape3D.new(); var bs := BoxShape3D.new()
		var sz := Vector2(0.36, 0.225)
		if q.mesh is QuadMesh: sz = (q.mesh as QuadMesh).size
		bs.size = Vector3(sz.x, sz.y, 0.02); cs.shape = bs; body.add_child(cs); q.add_child(body); body.set_meta("ctl", "MFD%d" % i)
		scr.append({"vp": vp, "pane": p, "page": [0, 1, 2][min(i, 2)], "boot": -10.0, "on": false, "mat": m})
		i += 1

func cycle(i: int) -> void:
	if i < scr.size(): scr[i].page = (scr[i].page + 1) % PAGES.size()

func tick(dt: float) -> void:
	if scr.is_empty(): return
	acc += dt
	if acc < 0.1: return
	acc = 0.0
	var t: float = g.T
	for i in scr.size():
		var s: Dictionary = scr[i]
		var on: bool = g.console.screen_on(i + 1)
		if on and not s.on: s.boot = Time.get_ticks_msec() / 1000.0
		s.on = on
		s.pane.queue_redraw(); s.vp.render_target_update_mode = SubViewport.UPDATE_ONCE

# ---------------- drawing ----------------
var F: Font
func _f() -> Font:
	if F == null: F = U.cjk()
	return F

func txt(c: Control, p: Vector2, s: String, size := 18, col := Color(0.85, 0.93, 1.0), align := HORIZONTAL_ALIGNMENT_LEFT, w := -1.0) -> void:
	c.draw_string(_f(), p, s, align, w, size, col)

func draw_page(c: Control, i: int) -> void:
	var s: Dictionary = scr[i]
	c.draw_rect(Rect2(0, 0, W, H), Color(0.01, 0.015, 0.02))
	if not s.on: return
	var since: float = Time.get_ticks_msec() / 1000.0 - float(s.boot)
	if since < 2.2:
		c.draw_rect(Rect2(0, 0, W, H), Color(0.02, 0.05, 0.09))
		txt(c, Vector2(0, 170), "启航 · 显示控制单元", 30, Color(0.7, 0.85, 1.0), HORIZONTAL_ALIGNMENT_CENTER, W)
		txt(c, Vector2(0, 215), "自检中 %d%%" % int(clampf(since / 2.0, 0.0, 1.0) * 100.0), 20, Color(0.6, 0.75, 0.9), HORIZONTAL_ALIGNMENT_CENTER, W)
		c.draw_rect(Rect2(170, 240, 300 * clampf(since / 2.0, 0.0, 1.0), 6), Color(0.4, 0.8, 1.0))
		return
	var bg := Color(0.02, 0.06, 0.1)
	c.draw_rect(Rect2(0, 0, W, H), bg)
	# header with page tabs (soft keys)
	for k in PAGES.size():
		var x := 8 + k * 104
		var sel: bool = k == s.page
		c.draw_rect(Rect2(x, H - 30, 98, 24), Color(0.2, 0.45, 0.3) if sel else Color(0.12, 0.16, 0.2))
		txt(c, Vector2(x, H - 12), PAGES[k], 15, Color(0.85, 1.0, 0.9) if sel else Color(0.7, 0.78, 0.85), HORIZONTAL_ALIGNMENT_CENTER, 98)
	txt(c, Vector2(14, 28), "%s   %s" % [PAGES[s.page], Hud.fmt_t(g.T)], 20, Color(0.55, 0.8, 1.0))
	c.draw_line(Vector2(10, 38), Vector2(W - 10, 38), Color(0.4, 0.6, 0.8, 0.4), 1)
	match s.page:
		0: _flight(c)
		1: _mission(c)
		2: _eps(c)
		3: _ecls(c)
		4: _prop(c)
		5: _comm(c)

func _kv(c: Control, x: float, y: float, k: String, v: String, col := Color(0.92, 0.96, 1.0)) -> void:
	txt(c, Vector2(x, y), k, 15, Color(0.5, 0.72, 0.95)); txt(c, Vector2(x + 120, y), v, 17, col)

func _flight(c: Control) -> void:
	var mach: float = g.get_meta("mach", g.vel / 330.0)
	_kv(c, 16, 70, "高度 ALT", "%.2f km" % (g.alt / 1000.0)); _kv(c, 16, 98, "速度 VEL", "%d m/s" % int(g.vel))
	_kv(c, 16, 126, "过载 G", "%.2f g" % g.gload, Color(1, 0.75, 0.3) if g.gload > 3.5 else Color(0.92, 0.96, 1.0))
	_kv(c, 16, 154, "动压 Q", "%.1f kPa" % (g.qdyn / 1000.0)); _kv(c, 16, 182, "马赫 M", "%.2f" % mach)
	# attitude indicator (pitch from local vertical)
	var cx := 470.0; var cy := 140.0; var r := 90.0
	var pitch_deg := 90.0
	if g.rocket != null:
		var up: Vector3 = (g.rocket.global_position - (g.site.global_position + Vector3(0, -Earth.R, 0))).normalized()
		pitch_deg = rad_to_deg(asin(clampf(g.rocket.global_transform.basis.y.dot(up), -1.0, 1.0)))
	var off := clampf((pitch_deg - 45.0) * 2.0, -r, r)
	c.draw_circle(Vector2(cx, cy), r, Color(0.35, 0.22, 0.12))
	c.draw_rect(Rect2(cx - r * 0.72, cy - r * 0.72, r * 1.44, r * 0.72 + off * 0.72), Color(0.18, 0.4, 0.75))
	for k in range(-3, 4):
		var yy := cy + off * 0.72 + k * 22.0
		if absf(yy - cy) < r * 0.7: c.draw_line(Vector2(cx - 26, yy), Vector2(cx + 26, yy), Color(1, 1, 1, 0.7), 1)
	c.draw_arc(Vector2(cx, cy), r, 0, TAU, 48, Color(0.7, 0.8, 0.9), 2)
	c.draw_line(Vector2(cx - 40, cy), Vector2(cx + 40, cy), Color(1, 0.8, 0.2), 3)
	txt(c, Vector2(cx - 60, cy + r + 22), "俯仰 %.1f°" % pitch_deg, 16, Color(0.85, 0.9, 1.0), HORIZONTAL_ALIGNMENT_CENTER, 120)
	# trajectory sketch (alt vs time)
	c.draw_rect(Rect2(16, 210, 330, 140), Color(0.03, 0.09, 0.14)); c.draw_rect(Rect2(16, 210, 330, 140), Color(0.3, 0.5, 0.7, 0.5), false, 1)
	var tt := clampf(g.T / 600.0, 0.0, 1.0)
	for k in 30:
		var u0 := k / 30.0; var u1 := (k + 1) / 30.0
		var h0 := 1.0 - pow(1.0 - u0, 2.2); var h1 := 1.0 - pow(1.0 - u1, 2.2)
		c.draw_line(Vector2(16 + u0 * 330, 350 - h0 * 130), Vector2(16 + u1 * 330, 350 - h1 * 130), Color(0.5, 0.7, 0.9, 0.6), 1)
	c.draw_circle(Vector2(16 + tt * 330, 350 - clampf(g.alt / 200000.0, 0.0, 1.0) * 130), 5, Color(1, 0.7, 0.2))
	txt(c, Vector2(22, 228), "计划弹道 · 高度/时间", 13, Color(0.5, 0.7, 0.9))

func _mission(c: Control) -> void:
	txt(c, Vector2(0, 100), Hud.fmt_t(g.T), 54, Color(1, 1, 1), HORIZONTAL_ALIGNMENT_CENTER, W)
	txt(c, Vector2(0, 132), String(g.hud.phase_l.text), 18, Color(1, 0.75, 0.35), HORIZONTAL_ALIGNMENT_CENTER, W)
	var y := 170.0
	if g.rocket != null and "events" in g.rocket:
		var n := 0
		for e in g.rocket.events:
			if float(e[0]) + 2.0 < g.T - 8.0: continue
			var past: bool = float(e[0]) + 2.0 <= g.T
			txt(c, Vector2(30, y), "T+%03d" % int(e[0]), 16, Color(0.45, 0.6, 0.7) if past else Color(0.95, 0.97, 1.0))
			txt(c, Vector2(120, y), String(e[2]), 16, Color(0.45, 0.6, 0.7) if past else Color(0.95, 0.97, 1.0))
			y += 24.0; n += 1
			if n >= 5: break
	var cw: Array = g.console.cw_active
	y = 300.0
	for a in cw.slice(0, 3):
		txt(c, Vector2(30, y), ("▲ " if a[1] == "W" else "△ ") + String(a[2]), 15, Color(1, 0.4, 0.3) if a[1] == "W" else Color(1, 0.72, 0.3)); y += 20

func _eps(c: Control) -> void:
	var P: Dictionary = g.console.PW
	_kv(c, 16, 70, "母线 A", "%.1f V  %.1f A" % [P.vA, P.ldA / 28.0], Color(0.4, 1, 0.6) if P.A else Color(1, 0.4, 0.3))
	_kv(c, 16, 98, "母线 B", "%.1f V  %.1f A" % [P.vB, P.ldB / 28.0], Color(0.4, 1, 0.6) if P.B else Color(1, 0.4, 0.3))
	_kv(c, 16, 126, "交流母线", "115 V 400 Hz" if P.AC else "失电", Color(0.4, 1, 0.6) if P.AC else Color(1, 0.4, 0.3))
	_kv(c, 16, 154, "地面电源", "已连接" if P.gnd else "断开", Color(1, 0.75, 0.3) if P.gnd else Color(0.92, 0.96, 1.0))
	for i in 4:
		var v: float = g.console.bat[i]
		c.draw_rect(Rect2(360, 60 + i * 34, 220, 20), Color(0.1, 0.14, 0.18))
		c.draw_rect(Rect2(360, 60 + i * 34, 220 * v / 100.0, 20), Color(0.3, 0.8, 0.5) if g.console.S.get("BAT%d" % (i + 1), false) else Color(0.35, 0.4, 0.45))
		txt(c, Vector2(366, 76 + i * 34), "电池 %d  %d%%" % [i + 1, int(v)], 14, Color(1, 1, 1))
	_kv(c, 16, 200, "跳闸断路器", "%d" % g.console.tripped.size(), Color(1, 0.6, 0.3) if g.console.tripped.size() > 0 else Color(0.92, 0.96, 1.0))

func _ecls(c: Control) -> void:
	var k = g.console
	_kv(c, 16, 70, "舱压", "%.1f kPa" % k.cabP, Color(1, 0.4, 0.3) if k.cabP < 90.0 else Color(0.92, 0.96, 1.0))
	_kv(c, 16, 98, "氧浓度", "%.1f %%" % k.o2); _kv(c, 16, 126, "二氧化碳", "%.2f kPa" % k.co2, Color(1, 0.7, 0.3) if k.co2 > 1.2 else Color(0.92, 0.96, 1.0))
	_kv(c, 16, 154, "舱温", "%.1f °C" % k.temp); _kv(c, 16, 182, "湿度", "%d %%" % int(k.hum)); _kv(c, 16, 210, "设备温度", "%.1f °C" % k.avT, Color(1, 0.6, 0.3) if k.avT > 45.0 else Color(0.92, 0.96, 1.0))
	_kv(c, 330, 70, "服装回路", "正常" if k.suit_ok() else "失效", Color(0.4, 1, 0.6) if k.suit_ok() else Color(1, 0.4, 0.3))
	_kv(c, 330, 98, "冷却泵", "%d / 2" % k.gly_n()); _kv(c, 330, 126, "风机", "%d / 2" % k.n_on(["CFAN1", "CFAN2"])); _kv(c, 330, 154, "净化器", "%d / 2" % k.n_on(["CO2A", "CO2B"]))
	_kv(c, 330, 182, "检漏", "通过" if k.leak_ok else ("进行中" if k.leak_t >= 0.0 else "—"))

func _prop(c: Control) -> void:
	var k = g.console
	_kv(c, 16, 70, "贮箱增压", "2.1 MPa" if k.pw("TKPRS") else "0.4 MPa"); _kv(c, 16, 98, "姿控可用", "%d %%" % int(k.rcs_k() * 100.0), Color(0.4, 1, 0.6) if k.rcs_k() > 0.0 else Color(1, 0.4, 0.3))
	for q in 4:
		var id: String = ["QA", "QB", "QC", "QD"][q]
		_kv(c, 16, 126 + q * 26, "喷管组 " + "ABCD"[q], "打开" if k.pw(id) else "关闭")
	_kv(c, 330, 70, "轨控发动机", "预位" if k.pw("ENGARM") else "保险"); _kv(c, 330, 98, "离轨条件", "满足" if k.deo_ready() else "不满足", Color(0.4, 1, 0.6) if k.deo_ready() else Color(1, 0.7, 0.3))
	_kv(c, 330, 126, "火工品", "%d / 2" % k.n_on(["PYRA", "PYRB"])); _kv(c, 330, 154, "程序器", "%d / 2" % k.n_on(["SEQA", "SEQB"]))

func _comm(c: Control) -> void:
	var k = g.console
	for row in [["S频段", "SBAND"], ["中继天线", "RELAY"], ["超短波", "UHF"], ["搜救电台", "VHF"], ["舱内对讲", "ICOM"], ["遥测", "TLM"], ["数据记录", "RCDR"], ["着陆信标", "BCN"]]:
		var i: int = [["S频段", "SBAND"], ["中继天线", "RELAY"], ["超短波", "UHF"], ["搜救电台", "VHF"], ["舱内对讲", "ICOM"], ["遥测", "TLM"], ["数据记录", "RCDR"], ["着陆信标", "BCN"]].find(row)
		_kv(c, 16 + (i / 4) * 310, 70 + (i % 4) * 28, row[0], "开" if k.pw(row[1]) else "关", Color(0.4, 1, 0.6) if k.pw(row[1]) else Color(0.6, 0.65, 0.7))
	_kv(c, 16, 200, "天地链路", "锁定" if g.sfx.comm_ok else "无信号", Color(0.4, 1, 0.6) if g.sfx.comm_ok else Color(1, 0.4, 0.3))

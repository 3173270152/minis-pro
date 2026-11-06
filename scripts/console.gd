## Crew console: physical switch hardware + the spacecraft systems model behind it.
## Every toggle, guarded switch, push button and circuit breaker is wired to EPS / avionics / comm / ECLSS / RCS / pyro logic.
class_name Console
extends Node

signal changed(id: String)
signal caution(level: String, msg: String)

const CELL_SW := Vector2(0.05, 0.078)
const CELL_CB := Vector2(0.036, 0.046)

var SW := {}            # id -> def dict
var SWL: Array = []     # defs available on this vehicle
var S := {}             # id -> bool state (switches and breakers "cb_X" / "cb2_X")
var pushed := {}
var tripped := {}
var cells := {}         # id -> cell dict (panel, index, kind, node refs)
var panels: Array = []
var rocket_kind := "qihang"

# systems state
var PW := {"A": false, "B": false, "AC": false, "gnd": false, "ldA": 0.0, "ldB": 0.0, "ldAC": 0.0, "vA": 0.0, "vB": 0.0}
var bat := [100.0, 100.0, 100.0, 100.0]
var cabP := 101.3
var o2 := 21.0
var co2 := 0.3
var temp := 22.4
var avT := 24.0
var hum := 45.0
var hyp := 0.0
var leak_t := -1.0
var leak_p0 := 0.0
var leak_ok := false
var hooks := false
var vestP := 0.0
var rcs_cold := 0.0
var rcs_frozen := false
var lamp_until := 0.0
var alarm_on := false
var cw_active: Array = []
var _cw_state := {}
var _dev := {}
var _time := 0.0
var _anim: Array = []

# mission context supplied by the game
var phase := "prelaunch"      # prelaunch / ascent / orbit / rdv / docked / deorbit / entry / landed
var hatch_closed := false
var on_ground_power := true   # umbilical still connected
var in_space := false

func _init(kind := "qihang") -> void:
	rocket_kind = kind
	for r in CD.SWT:
		if r.size() > 8 and r[8] != null and not String(r[8]).split(" ").has(kind): continue
		var d := {"id": r[0], "cn": r[1], "en": r[2], "kind": r[3], "bus": r[4], "bus2": r[5], "w": float(r[6]), "sp": r[7]}
		SW[d.id] = d; SWL.append(d); S[d.id] = d.id == "GND"
		if d.bus != null:
			S["cb_" + d.id] = true
			if d.bus2 != null: S["cb2_" + d.id] = true

# ================= power =================
func bus_on(b) -> bool:
	match b:
		"A": return PW.A
		"B": return PW.B
		"AC": return PW.AC
	return false

func pw(id: String) -> bool:
	if not SW.has(id): return false
	var d: Dictionary = SW[id]
	if not S.get(id, false): return false
	if d.bus == null: return true
	return (S.get("cb_" + id, false) and bus_on(d.bus)) or (d.bus2 != null and S.get("cb2_" + id, false) and bus_on(d.bus2))

func n_on(ids: Array) -> int:
	var n := 0
	for i in ids: if pw(i): n += 1
	return n

func bat_ok(i: int) -> bool:
	return SW.has("BAT%d" % i) and S.get("BAT%d" % i, false) and bat[i - 1] > 0.0

func power_eval(dt: float) -> void:
	PW.gnd = S.get("GND", false) and on_ground_power
	var sa: bool = S.get("_sa_deployed", false) and in_space
	var sA: bool = PW.gnd or bat_ok(1) or bat_ok(2) or sa
	var sB: bool = PW.gnd or bat_ok(3) or bat_ok(4) or sa
	PW.A = S.get("MAINA", false) and (sA or (S.get("TIE", false) and sB))
	PW.B = S.get("MAINB", false) and (sB or (S.get("TIE", false) and sA))
	PW.AC = (S.get("INV1", false) and S.get("cb_INV1", false) and PW.A) or (S.get("INV2", false) and S.get("cb_INV2", false) and PW.B)
	var ld := {"A": 0.0, "B": 0.0, "AC": 0.0}
	for d in SWL:
		if d.bus == null or not pw(d.id): continue
		var b: String = d.bus
		if d.bus2 != null and not (S.get("cb_" + d.id, false) and bus_on(d.bus)): b = d.bus2
		ld[b] += d.w
	PW.ldA = ld.A; PW.ldB = ld.B; PW.ldAC = ld.AC
	var wA: float = ld.A + ld.AC * 0.55; var wB: float = ld.B + ld.AC * 0.45
	if not PW.gnd and dt > 0.0:
		var k := dt * 2.2e-5
		var fc := rocket_kind == "saturn" or rocket_kind == "shuttle"
		if not sa and not fc:
			var ua := [1, 2].filter(func(i): return bat_ok(i)); var ub := [3, 4].filter(func(i): return bat_ok(i))
			for i in ua: bat[i - 1] = maxf(0.0, bat[i - 1] - k * wA / ua.size())
			for i in ub: bat[i - 1] = maxf(0.0, bat[i - 1] - k * wB / ub.size())
		elif sa and pw("CHG"):
			for i in 4: if S.get("BAT%d" % (i + 1), false): bat[i] = minf(100.0, bat[i] + dt * 0.02)
	var mb := min_bat()
	var v0 := 28.6 if PW.gnd else (27.9 - (3.0 if mb < 15.0 else 0.0))
	PW.vA = (v0 - wA * 0.0009) if PW.A else 0.0
	PW.vB = (v0 - wB * 0.0009) if PW.B else 0.0

func min_bat() -> float:
	var m := 100.0
	for i in 4: if bat_ok(i + 1): m = minf(m, bat[i])
	return m

# ================= capability gates used by the flight =================
func power() -> bool: return PW.A or PW.B
func gnc_n() -> int: return n_on(["GNC1", "GNC2", "GNC3"])
func imu_n() -> int: return n_on(["IMU1", "IMU2"])
func pyro_ok() -> bool: return n_on(["SEQA", "SEQB"]) > 0 and n_on(["PYRA", "PYRB"]) > 0
func pyro_man_ok() -> bool: return n_on(["PYRA", "PYRB"]) > 0
func rcs_k() -> float:
	if not (pw("TKPRS") and (pw("RCSA") or pw("RCSB"))) or rcs_frozen: return 0.0
	return n_on(["QA", "QB", "QC", "QD"]) / 4.0
func esc_hw() -> bool: return (not SW.has("LES") or pw("LES")) and pyro_ok()
func els_auto() -> bool: return not SW.has("ELS") or (pw("ELS") and pyro_ok())
func retro_ok() -> bool: return not SW.has("RETRO") or (pw("RETRO") and pyro_man_ok())
func cws_ok() -> bool: return pw("CWS")
func screen_on(i: int) -> bool: return power() and pw("DBUS") and pw("DSP%d" % i)
func comm_link(near_ground: bool, near_station: bool) -> bool:
	return (pw("SBAND") and (near_ground or pw("RELAY"))) or (pw("UHF") and near_station) or ((pw("VHF") or pw("UHF")) and phase == "landed")
func suit_ok() -> bool: return pw("SUITO2") and n_on(["O2A", "O2B"]) > 0 and n_on(["SFAN1", "SFAN2"]) > 0
func deo_ready() -> bool:
	return pw("ENGARM") and pw("DEO") and pw("PROPISO") and pw("TKPRS") and n_on(["GMB1", "GMB2"]) > 0 and gnc_n() > 0 and imu_n() > 0 and rcs_k() > 0.0
func lcc_fails() -> Array:
	var f := []
	for id in CD.LCC: if SW.has(id) and not pw(id): f.append(id)
	if not leak_ok: f.append("LEAKCK")
	if pw("DUMP"): f.append("DUMP")
	if not PW.AC: f.append("INV1")
	return f
func internal_power() -> bool:
	var n := 0
	for i in 4: if bat_ok(i + 1): n += 1
	return n >= 2 and not S.get("GND", false)

# ================= operating controls =================
func kind_of(id: String) -> String:
	return "c" if id.begins_with("cb") else String(SW[id].kind)

func def_of(id: String) -> Dictionary:
	if id.begins_with("cb"): return SW[id.trim_prefix("cb2_").trim_prefix("cb_")]
	return SW[id]

func set_switch(id: String, on: bool, quiet := false) -> void:
	if not S.has(id) or S[id] == on: return
	S[id] = on
	if id.begins_with("cb") and on: tripped.erase(id)
	if cells.has(id): _pose(cells[id], quiet)
	power_eval(0.0)
	changed.emit(id)

func push(id: String) -> String:
	var done := true; var msg := ""
	match id:
		"HORN": alarm_on = false
		"ANNTST":
			if power(): lamp_until = _time + 3.0
			else: done = false
		"LEAKCK":
			done = false
			if not power(): msg = "没有电，检漏程序无法启动"
			elif not hatch_closed: msg = "舱门未关闭，无法检漏"
			else: leak_t = _time; leak_p0 = cabP; msg = "舱体检漏开始 · 监测舱压 15 秒"
		"HOOKS":
			done = false
			if phase != "docked": msg = "未捕获，对接锁不能闭合"
			elif not pw("PROBE"): msg = "对接机构未通电"
			else: hooks = true; done = true
		"SA":
			done = false
			if not in_space: msg = "入轨前不能展开帆板"
			elif not pyro_man_ok(): msg = "火工品母线未预位，帆板压紧机构无法解锁"
			else: S["_sa_deployed"] = true; done = true
	if done: pushed[id] = true
	if cells.has(id): cells[id].press = _time + 0.2
	changed.emit(id)
	return msg

## returns a status message for the HUD ("" if nothing to say)
func operate(id: String) -> String:
	if not cells.has(id): return ""
	var c: Dictionary = cells[id]
	var k: String = c.kind
	if (k == "g" or k == "gp") and not c.open:
		c.open = true; c.open_t = _time; _pose(c, false); return ""
	if k == "p" or k == "gp": return push(id)
	if k == "c" and not S[id] and tripped.has(id) and avT > 55.0: return "设备仍然过热，断路器再次跳开"
	set_switch(id, not S[id]); return ""

func step_push_done(id: String) -> bool:
	match id:
		"SA": return S.get("_sa_deployed", false)
		"LEAKCK": return leak_ok
		"HOOKS": return hooks
	return pushed.get(id, false)

func step_ok(st: Array) -> bool:
	var id: String = st[0]
	if id == "@eq": return hooks and absf(cabP - vestP) < 0.4
	if not SW.has(id): return true
	if typeof(st[1]) == TYPE_STRING: return step_push_done(id)
	var want := int(st[1]) == 1
	return S.get(id, false) == want and (not want or SW[id].bus == null or pw(id))

## apply procedures instantly (skip / challenges)
func auto_upto(k: String) -> void:
	for P in CD.PROC:
		for st in P.s:
			var id: String = st[0]
			if id.begins_with("@") or not SW.has(id): continue
			if typeof(st[1]) == TYPE_STRING:
				if id == "LEAKCK": leak_ok = true
				elif id != "SA": pushed[id] = true
			else: set_switch(id, int(st[1]) == 1, true)
		if P.k == k: break
	power_eval(0.0)

# ================= simulation tick =================
func tick(dt: float) -> void:
	_time += dt
	power_eval(dt)
	var sealed := hatch_closed and phase != "landed"
	var amb := 0.0 if in_space else 101.3
	# cabin atmosphere
	var P0 := cabP; var dP := 0.0
	if not sealed: dP += (101.3 - P0) * minf(1.0, dt * 0.8)
	else:
		dP -= (P0 - amb) * 0.0006 * dt
		if pw("DUMP"): dP -= (P0 - amb) * 0.035 * dt
		if pw("EQV"):
			if phase == "docked" and hooks:
				var f := (P0 - vestP) * 0.25 * dt; dP -= f * 0.15; vestP += f
			else: dP -= (P0 - amb) * 0.012 * dt
		if pw("PREG") and n_on(["O2A", "O2B"]) > 0 and P0 < 101.3: dP += minf(101.3 - P0, (0.45 if pw("N2") else 0.25) * dt)
	cabP = maxf(0.0, P0 + dP)
	var o2sup := pw("PREG") and n_on(["O2A", "O2B"]) > 0
	o2 += ((21.0 - o2) * 0.05 * dt if o2sup else -0.004 * dt) if sealed else (21.0 - o2) * minf(1.0, dt)
	var scrub := n_on(["CO2A", "CO2B"]) * (1.0 if n_on(["CFAN1", "CFAN2"]) > 0 else 0.15)
	co2 = maxf(0.25, co2 + (0.006 - 0.0075 * scrub) * dt) if sealed else maxf(0.04, co2 - dt * 0.05)
	var avW: float = PW.ldA + PW.ldB + PW.ldAC; var gly := n_on(["GLY1", "GLY2"])
	avT += ((avW / 600.0) * 0.3 if power() else 0.0) * dt - ((avT - 24.0) * 0.03 * gly * dt if gly > 0 else (avT - temp) * 0.002 * dt)
	if avT > 62.0:
		var n := 0
		for id in ["GNC1", "GNC2", "GNC3", "DSP1", "DSP2", "DSP3", "DBUS", "IMU1", "IMU2"]:
			for p in ["cb_", "cb2_"]:
				if S.get(p + id, false): S[p + id] = false; tripped[p + id] = true; n += 1; if cells.has(p + id): _pose(cells[p + id], false)
		avT = 58.0
		if n > 0: caution.emit("W", "设备过热，%d 个断路器跳闸" % n)
	var space := in_space and sealed
	temp += ((0.01 if pw("HTR") and temp < 22.5 else 0.0) + avW * 0.0000035 - ((temp + 10.0) * 0.00035 if space else (temp - 22.0) * 0.002)) * dt
	hum = clampf(hum + ((-0.06 if pw("H2OSEP") else 0.035) if sealed else -0.2) * dt, 35.0, 98.0)
	var thin := cabP < 62.0 or o2 < 15.5
	hyp = clampf(hyp + (dt / 75.0 if thin and not suit_ok() else -dt / 25.0), 0.0, 1.0)
	if leak_t >= 0.0 and _time - leak_t > 15.0:
		leak_ok = (leak_p0 - cabP) < 0.25 and hatch_closed and not pw("DUMP") and not pw("EQV"); leak_t = -1.0
		if leak_ok: pushed["LEAKCK"] = true
		caution.emit("I", "检漏通过，舱体密封良好" if leak_ok else "检漏未通过，舱压在下降")
	if space and not pw("RCSHTR"): rcs_cold += dt
	else: rcs_cold = maxf(0.0, rcs_cold - dt * 3.0)
	if rcs_cold > 150.0 and not rcs_frozen: rcs_frozen = true
	if rcs_cold < 30.0: rcs_frozen = false
	# guard covers close themselves after 9 s, lever animation
	for id in cells:
		var c: Dictionary = cells[id]
		if c.get("open", false) and _time - c.open_t > 9.0: c.open = false; _pose(c, false)
		if c.has("ang") and absf(c.ang - c.tgt) > 0.001:
			c.ang = lerpf(c.ang, c.tgt, minf(1.0, dt * 22.0)); _pose(c, false, true)
	_cw_tick()
	_refresh_visuals()

# ================= caution & warning =================
func _cw_list() -> Array:
	var fly := phase == "ascent" or phase == "entry"
	return [
		["busA", "W", "主母线 A 欠压", not PW.A, true], ["busB", "W", "主母线 B 欠压", not PW.B, true],
		["ac", "W", "交流母线失电 · 风机/泵/惯组停转", not PW.AC, true], ["dbus", "W", "数据总线中断", not pw("DBUS"), true],
		["gnc0", "W", "三台制导计算机全部离线", gnc_n() == 0, true], ["gnc", "C", "制导计算机冗余丧失", gnc_n() in [1, 2], true],
		["imu0", "W", "惯性测量单元全部失效", imu_n() == 0, true], ["cabP", "W", "舱压低", cabP < 95.0 and hatch_closed, true],
		["dump", "W", "舱内泄压阀打开", pw("DUMP") and hatch_closed, true], ["o2", "W", "供氧中断", n_on(["O2A", "O2B"]) == 0, true],
		["suit", "W", "航天服供氧/通风失效", not suit_ok(), fly], ["co2", "C", "二氧化碳分压高", co2 > 1.2, true],
		["gly", "W", "冷却回路停泵", gly_n() == 0, true], ["avT", "W", "设备舱过热", avT > 50.0, true],
		["trip", "C", "断路器跳闸", tripped.size() > 0, true], ["tlm", "C", "遥测发射机关闭", not pw("TLM"), true],
		["rcs0", "W", "姿控系统不可用", rcs_k() == 0.0, in_space], ["les", "W", "逃逸系统未预位", SW.has("LES") and not pw("LES"), phase == "ascent"],
		["abt", "C", "自动中止已关闭", not pw("ABTAUTO"), phase == "ascent"], ["els", "W", "着陆程序未启用", SW.has("ELS") and not pw("ELS"), phase == "entry"],
		["pyro", "C", "火工品母线处于预位", n_on(["PYRA", "PYRB"]) > 0, phase == "orbit"], ["engdk", "W", "对接状态下轨控发动机预位", pw("ENGARM") or pw("DEO"), phase == "docked"],
		["bat", "C", "电池电量低", min_bat() < 20.0, true], ["cold", "C", "舱温低", temp < 17.0, true], ["hum", "C", "舱内湿度高", hum > 80.0, true],
	]

func gly_n() -> int: return n_on(["GLY1", "GLY2"])

func _cw_tick() -> void:
	if not hatch_closed: cw_active = []; return
	var act := []; var fresh = null
	for e in _cw_list():
		var k: String = e[0]; var bad: bool = e[3]; var gate: bool = e[4]
		var s: Dictionary = _cw_state.get(k, {"arm": false, "ok": 0.0, "on": false}); _cw_state[k] = s
		if not gate: s.on = false; s.ok = 0.0; s.arm = false; continue
		if not bad:
			s.on = false
			if s.ok == 0.0: s.ok = _time
			if _time - s.ok > 1.5: s.arm = true
			continue
		s.ok = 0.0
		if s.arm or k in ["les", "suit", "engdk", "dump", "trip"]:
			act.append([k, e[1], e[2]])
			if not s.on:
				s.on = true
				if fresh == null or e[1] == "W": fresh = e
	# procedure deviation: a completed checklist step that has been undone
	for P in CD.PROC:
		for st in P.s:
			var id: String = st[0]
			if id.begins_with("@") or typeof(st[1]) == TYPE_STRING or not SW.has(id): continue
			var key: String = P.k + id
			if step_ok(st): _dev[key] = 1; continue
			if _dev.get(key, 0) >= 1:
				if _dev[key] == 1 and fresh == null: fresh = ["dev", "C", "程序偏离 · " + SW[id].cn]
				_dev[key] = 2; act.append(["dev" + id, "C", "程序偏离 · " + SW[id].cn])
	cw_active = act
	if fresh != null and cws_ok():
		if fresh[1] == "W": alarm_on = true
		caution.emit(fresh[1], fresh[2])

# ================= hardware =================
var _m_plate: StandardMaterial3D
var _m_lever: StandardMaterial3D
var _m_nut: StandardMaterial3D
var _m_guard: StandardMaterial3D
var _m_cb: StandardMaterial3D
var _m_collar: StandardMaterial3D

func _mats() -> void:
	_m_lever = U.mat(Color(0.86, 0.87, 0.88), 0.18, 1.0)
	_m_nut = U.mat(Color(0.62, 0.63, 0.65), 0.3, 0.9)
	_m_guard = U.mat(Color(0.85, 0.2, 0.1, 0.42), 0.15, 0.0); _m_guard.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_m_cb = U.mat(Color(0.06, 0.06, 0.07), 0.45, 0.2)
	_m_collar = U.mat(Color(0.95, 0.95, 0.93), 0.5, 0.0)

func panel_list() -> Array:
	var L := []
	for p in CD.PANELS:
		var q: Dictionary = p.duplicate(true)
		if p.has("bus"):
			var ids := []
			for d in SWL:
				if d.bus == p.bus: ids.append("cb_" + d.id)
				if d.bus2 == p.bus: ids.append("cb2_" + d.id)
			q.ids = ids
		else: q.ids = p.ids.filter(func(i): return SW.has(i))
		L.append(q)
	return L

func find_panel(L: Array, k: String) -> Dictionary:
	for p in L: if p.k == k: return p
	return {}

## surfaces: Array of {node, x, y, w, h} (top-left origin, +x right, -y down); panels flow into them in order
func flow(surfs: Array, specs: Array) -> void:
	if _m_lever == null: _mats()
	var si := 0; var cx := 0.0; var cy := 0.0; var row_h := 0.0; var gap := 0.012
	for spec in specs:
		if spec.is_empty() or spec.ids.is_empty(): continue
		var brk: bool = spec.has("bus")
		var cell: Vector2 = CELL_CB if brk else CELL_SW
		var guard := 0
		while guard < 30:
			guard += 1
			if si >= surfs.size(): push_warning("console: no room for " + spec.k); return
			var s: Dictionary = surfs[si]
			var cols: int = mini(int(spec.cols), spec.ids.size())
			var W := cols * cell.x + 0.024
			while W > s.w + 1e-6 and cols > 2: cols -= 1; W = cols * cell.x + 0.024
			var Hh := ceili(float(spec.ids.size()) / cols) * cell.y + 0.046
			if cx + W > s.w + 1e-6: cx = 0.0; cy += row_h + gap; row_h = 0.0; continue
			if cy + Hh > s.h + 1e-6: si += 1; cx = 0.0; cy = 0.0; row_h = 0.0; continue
			_build_panel(s.node, spec, cols, Vector2(s.x + cx, s.y - cy), cell, W, Hh)
			cx += W + gap; row_h = maxf(row_h, Hh); break

func _build_panel(parent: Node3D, spec: Dictionary, cols: int, tl: Vector2, cell: Vector2, W: float, Hh: float) -> void:
	var g := Node3D.new(); g.position = Vector3(tl.x + W * 0.5, tl.y - Hh * 0.5, 0.004); parent.add_child(g)
	var P := {"spec": spec, "node": g, "W": W, "H": Hh, "cell": cell, "cols": cols, "ids": spec.ids, "brk": spec.has("bus")}
	panels.append(P)
	# legend artwork rendered once by a 2D viewport (crisp CJK text), then shown on the plate
	var vp := SubViewport.new(); vp.size = Vector2i(int(W * 2400), int(Hh * 2400)); vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE; vp.disable_3d = true
	g.add_child(vp)
	var bg := ColorRect.new(); bg.color = Color(0.23, 0.25, 0.28); bg.size = Vector2(vp.size); vp.add_child(bg)
	var title := ColorRect.new(); title.color = Color(0.15, 0.16, 0.18); title.size = Vector2(vp.size.x, 0.028 * 2400); vp.add_child(title)
	_lbl(vp, spec.n, Vector2(0.012, 0.004) * 2400, 34, Color(0.95, 0.95, 0.92))
	_lbl(vp, spec.e, Vector2(W * 0.55, 0.008) * 2400, 22, Color(0.7, 0.72, 0.76))
	var plate := MeshInstance3D.new(); var q := QuadMesh.new(); q.size = Vector2(W, Hh); plate.mesh = q
	var pm := StandardMaterial3D.new(); pm.albedo_texture = vp.get_texture(); pm.roughness = 0.7; pm.metallic = 0.2
	pm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_bake_later(vp, pm)
	pm.emission_enabled = true; pm.emission_texture = vp.get_texture(); pm.emission = Color(0, 0, 0); pm.emission_energy_multiplier = 0.6
	plate.material_override = pm; g.add_child(plate); P.plate_mat = pm
	U.box(g, Vector3(W + 0.008, Hh + 0.008, 0.01), Vector3(0, 0, -0.006), U.mat(Color(0.12, 0.13, 0.14), 0.5, 0.5))
	# hit area for picking
	var body := StaticBody3D.new(); body.collision_layer = 1 << 9; body.collision_mask = 0; var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = Vector3(W, Hh, 0.03)
	cs.shape = bs; body.add_child(cs); g.add_child(body); body.set_meta("panel", P)
	for i in spec.ids.size():
		var id: String = spec.ids[i]
		var r: int = int(i) / cols; var cc: int = int(i) % cols
		var pos := Vector2(-W * 0.5 + 0.012 + cell.x * (cc + 0.5), Hh * 0.5 - 0.034 - cell.y * (r + 0.5))
		_build_cell(g, vp, P, id, pos, cell)

## once the legend viewport has drawn, freeze it into a mipmapped texture (crisp at any distance) and free the viewport
func _bake_later(vp: SubViewport, pm: StandardMaterial3D) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img == null: return
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	pm.albedo_texture = t; pm.emission_texture = t
	vp.queue_free()

func _lbl(vp: SubViewport, t: String, at: Vector2, size: int, col: Color, center := false, w := 0.0) -> Label:
	var l := Label.new(); l.text = t; l.position = at; l.add_theme_font_size_override("font_size", size); l.add_theme_color_override("font_color", col)
	if center: l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; l.size = Vector2(w, size * 1.4)
	vp.add_child(l); return l

func _build_cell(g: Node3D, vp: SubViewport, P: Dictionary, id: String, pos: Vector2, cell: Vector2) -> void:
	var k := kind_of(id); var d := def_of(id)
	var c := {"id": id, "kind": k, "pos": pos, "panel": P, "open": false, "open_t": 0.0, "press": 0.0}
	var px := Vector2((pos.x + P.W * 0.5) * 2400, (P.H * 0.5 - pos.y) * 2400)
	var cw := cell.x * 2400
	# engraved legend above and below
	if k == "c":
		_lbl(vp, String(d.en).substr(0, 10), px + Vector2(-cw * 0.5, -cell.y * 2400 * 0.5 + 4), 15, Color(0.92, 0.92, 0.9), true, cw)
		_lbl(vp, String(d.cn).substr(0, 6) + ("·备" if id.begins_with("cb2") else ""), px + Vector2(-cw * 0.5, cell.y * 2400 * 0.18), 14, Color(0.82, 0.84, 0.86), true, cw)
	else:
		_lbl(vp, String(d.en).substr(0, 12), px + Vector2(-cw * 0.5, -cell.y * 2400 * 0.5 + 2), 17, Color(0.95, 0.95, 0.93), true, cw)
		_lbl(vp, d.cn, px + Vector2(-cw * 0.5, cell.y * 2400 * 0.26), 18, Color(0.86, 0.88, 0.9), true, cw)
		if k == "t" or k == "g":
			var valve: bool = CD.VERB_X.has(id) and CD.VERB_X[id][0] == "打开"
			_lbl(vp, ("OPEN" if valve else ("ARM" if k == "g" else "ON")), px + Vector2(cw * 0.18, -cell.y * 2400 * 0.24), 12, Color(0.65, 0.68, 0.72))
			_lbl(vp, ("CLOSE" if valve else ("SAFE" if k == "g" else "OFF")), px + Vector2(cw * 0.18, cell.y * 2400 * 0.08), 12, Color(0.65, 0.68, 0.72))
	var n := Node3D.new(); n.position = Vector3(pos.x, pos.y - 0.004, 0); g.add_child(n); c.node = n
	match k:
		"c":
			var knob := U.cyl(n, 0.0085, 0.0085, 0.012, Vector3(0, 0, 0.006), _m_cb, 12, Vector3(PI * 0.5, 0, 0))
			var col := U.cyl(n, 0.0088, 0.0088, 0.005, Vector3(0, 0, 0.002), _m_collar, 12, Vector3(PI * 0.5, 0, 0))
			c.knob = knob; c.collar = col
		"t", "g":
			U.cyl(n, 0.0105, 0.0105, 0.006, Vector3(0, 0, 0.003), _m_nut, 6, Vector3(PI * 0.5, 0, 0))
			var piv := Node3D.new(); piv.position.z = 0.006; n.add_child(piv)
			U.cyl(piv, 0.0035, 0.0055, 0.03, Vector3(0, 0, 0.015), _m_lever, 10, Vector3(PI * 0.5, 0, 0))
			U.sphere(piv, 0.0045, Vector3(0, 0, 0.031), _m_lever, 10)
			c.pivot = piv; c.ang = 0.6; c.tgt = 0.6
			var tb := MeshInstance3D.new(); var tq := QuadMesh.new(); tq.size = Vector2(0.009, 0.012); tb.mesh = tq; tb.position = Vector3(-0.019, 0.012, 0.0015)
			tb.material_override = U.emissive(Color(0.02, 0.02, 0.02), 1.0); n.add_child(tb); c.talk = tb
		"p", "gp":
			var b := U.rbox(n, Vector3(0.03, 0.03, 0.012), 0.004, Vector3(0, 0, 0.006), U.emissive(Color(0.5, 0.5, 0.5), 0.6))
			c.btn = b
	if k == "g" or k == "gp":
		var gp := Node3D.new(); gp.position = Vector3(0, 0.022, 0.008); n.add_child(gp)
		U.box(gp, Vector3(0.03, 0.003, 0.036), Vector3(0, -0.02, 0.018), _m_guard)
		U.box(gp, Vector3(0.003, 0.034, 0.036), Vector3(-0.015, -0.004, 0.018), _m_guard)
		U.box(gp, Vector3(0.003, 0.034, 0.036), Vector3(0.015, -0.004, 0.018), _m_guard)
		c.guard = gp
	var hit := StaticBody3D.new(); hit.collision_layer = 1 << 10; hit.collision_mask = 0
	var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = Vector3(cell.x * 0.95, cell.y * 0.95, 0.05); cs.shape = bs; cs.position.z = 0.02
	hit.add_child(cs); n.add_child(hit); hit.set_meta("ctl", id)
	cells[id] = c
	_pose(c, true)

func _pose(c: Dictionary, snap: bool, anim_only := false) -> void:
	var on: bool = S.get(c.id, false)
	match c.kind:
		"c":
			c.knob.position.z = 0.006 if on else 0.014
			c.collar.visible = not on
		"t", "g":
			c.tgt = -0.6 if on else 0.6
			if snap: c.ang = c.tgt
			c.pivot.rotation.x = c.ang
	if anim_only: return
	if c.has("guard"): c.guard.rotation.x = -1.9 if c.open else 0.0

func _refresh_visuals() -> void:
	var lit := (power() and pw("INTEG")) or lamp_until > _time
	var pnl := 0.6 if pw("PNL") else 0.0
	for P in panels: P.plate_mat.emission = Color(pnl, pnl * 0.93, pnl * 0.82)
	for id in cells:
		var c: Dictionary = cells[id]
		if c.has("talk"):
			var col := Color(0.02, 0.02, 0.02)
			if S.get(id, false): col = (Color(0.15, 1.6, 0.45) if lit else Color(0.05, 0.3, 0.1)) if pw(id) else Color(0.9, 0.9, 0.9) * (1.0 if lit else 0.3)
			c.talk.material_override.albedo_color = col; c.talk.material_override.emission = col
		if c.has("btn"):
			var red: bool = id in ["ABORT", "REPR", "CHREL"]; var amb: bool = id in ["SEPSM", "DROGUE", "CHUTE", "GEAR", "SA"]
			var k := 1.6 if lit else 0.35
			var col := Color(0.55, 0.58, 0.6) * k
			if red: col = Color(0.75, 0.06, 0.04) * k
			elif amb: col = Color(0.8, 0.5, 0.08) * k
			if step_push_done(id) and lit: col = Color(0.25, 1.4, 0.55) * k
			var m: StandardMaterial3D = c.btn.material_override; m.albedo_color = col; m.emission = col
			c.btn.position.z = 0.002 if c.press > _time else 0.006

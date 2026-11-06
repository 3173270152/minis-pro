## Qihang launch vehicle (modelled on Long March 2F proportions): 3.35 m core, four 2.25 m strap-on boosters,
## truss interstage, 3.8 m fairing over the spacecraft, escape tower with grid fins. Origin = bottom of core stage skirt.
class_name Rocket
extends Node3D

const R_CORE := 1.675
const R_BST := 1.125
const R_FAIR := 1.9
const Y_S1_TOP := 28.4
const Y_S2_BOT := 31.0
const Y_S2_TOP := 43.6
const Y_FAIR_BOT := 43.6
const Y_FAIR_CYL := 53.2
const Y_FAIR_TOP := 57.4
const Y_LES_TOP := 65.2
const Y_CAPSULE := 47.6   # floor of the return capsule (crew hatch level)

# per-vehicle interface (variants override in build())
var kind := "qihang"
var y_cap := Y_CAPSULE      # capsule floor above the core base
var r_hatch := R_FAIR       # radius of the body at the crew hatch (crew arm length)
var top := Y_LES_TOP
var cab := "shenzhou"       # cabin layout: shenzhou / apollo / dragon / shuttle
var has_les := true
var land := "land"          # land / sea / runway
var events: Array = []      # [t, key, label]
var cap_mount: Node3D       # parent for the crew cabin
var skin_white: ShaderMaterial
var stage1: Node3D
var stage2: Node3D
var boosters: Array[Node3D] = []
var fairing: Node3D
var les: Node3D
var engines: Array[Node3D] = []
var plume_points: Array[Node3D] = []

func _init(k := "qihang") -> void:
	kind = k

func _ready() -> void:
	skin_white = U.shader_mat("res://shaders/skin.gdshader", {"nz": U.noise_tex(0.02, false, 41, 512, 5), "ring_m": 2.4, "seams": 16.0, "grime": 0.35})
	stage1 = Node3D.new(); stage1.name = "Stage1"; add_child(stage1)
	stage2 = Node3D.new(); stage2.name = "Stage2"; add_child(stage2)
	if kind in ["saturn", "fh", "shuttle"]:
		RV.build(self)
	else:
		_core_stage()
		for i in 4: _booster(i)
		_interstage()
		_second_stage()
		_fairing()
		_spacecraft()
		_les()
		_markings()
	cap_mount = Node3D.new(); cap_mount.position.y = y_cap; add_child(cap_mount)
	if kind in ["saturn", "fh", "shuttle"]:
		if kind == "shuttle": cap_mount.position.x = -6.3
		return
	events = [[8.0, "tower", "程序转弯"], [62.0, "mach", "突破音速"], [75.0, "maxq", "最大动压"], [120.0, "lesj", "逃逸塔分离"], [140.0, "bsep", "助推器分离"],
		[158.0, "meco", "一级关机"], [160.0, "sep", "一二级分离"], [162.0, "ses", "二级点火"], [200.0, "fair", "整流罩分离"], [300.0, "nom", "飞行正常"], [584.0, "seco", "二级关机"], [590.0, "shipsep", "船箭分离 · 入轨"]]
	if kind == "cz2f": _cz2f_marks()

func _cz2f_marks() -> void:
	for c in fairing.get_children(): if c is Label3D: c.text = "神 舟"
	for c in stage2.get_children(): if c is Label3D: c.text = "CZ-2F"
	for c in stage1.get_children(): if c is Label3D and c.text == "启航": c.text = "长征二号F"

func _skin(params := {}) -> ShaderMaterial:
	var m: ShaderMaterial = skin_white.duplicate()
	for k in params: m.set_shader_parameter(k, params[k])
	return m

func _lathe(parent: Node, prof: PackedVector2Array, m: Material, seg := 72) -> MeshInstance3D:
	return U.put(parent, U.lathe(prof, seg), m)

# ---------- core stage ----------
func _core_stage() -> void:
	var m := _skin({"soot": 0.6})
	# skirt flare at the bottom, tanks, ring frames
	_lathe(stage1, PackedVector2Array([Vector2(R_CORE + 0.12, 0.0), Vector2(R_CORE + 0.05, 0.9), Vector2(R_CORE, 1.6), Vector2(R_CORE, Y_S1_TOP)]), m)
	var ringm := U.mat(Color(0.78, 0.78, 0.76), 0.5, 0.3)
	for y in [1.6, 3.2, 12.9, 14.4, 27.8]:
		_lathe(stage1, PackedVector2Array([Vector2(R_CORE + 0.025, y - 0.08), Vector2(R_CORE + 0.04, y), Vector2(R_CORE + 0.025, y + 0.08)]), ringm, 64)
	# booster attach fittings (thrust struts top and bottom)
	var steel := U.mat(Color(0.55, 0.56, 0.58), 0.45, 0.7, 1.0)
	for i in 4:
		var a := TAU * i / 4.0 + PI / 4.0; var d := Vector3(sin(a), 0, cos(a))
		for y in [2.2, 14.8]:
			U.box(stage1, Vector3(0.5, 0.6, 0.9), d * (R_CORE + 0.35) + Vector3(0, y, 0), steel, Vector3(0, a, 0))
		U.beam(stage1, d * (R_CORE + 0.1) + Vector3(0, 2.0, 0), d * (R_CORE + 0.75) + Vector3(0, 2.6, 0), 0.07, steel)
	# cable tunnel / conduit fairings running up the stage
	var tun := _skin({"seams": 4.0, "grime": 0.2})
	for a in [0.0, PI]:
		var t := U.box(stage1, Vector3(0.28, Y_S1_TOP - 2.0, 0.16), Vector3(sin(a) * (R_CORE + 0.06), (Y_S1_TOP + 2.0) * 0.5, cos(a) * (R_CORE + 0.06)), tun, Vector3(0, a, 0))
	# 4 x YF-20 style engines in a square, gimballed
	for i in 4:
		var a := TAU * i / 4.0 + PI / 4.0
		_engine(stage1, Vector3(sin(a), 0, cos(a)) * 0.85 + Vector3(0, 0.25, 0), 1.0)
	# base heat shield
	U.cyl(stage1, R_CORE + 0.05, R_CORE + 0.12, 0.12, Vector3(0, 0.3, 0), U.mat(Color(0.18, 0.18, 0.19), 0.8, 0.2, 1.5))

## one liquid engine: gimbal mount, turbopump, propellant ducts, regeneratively cooled bell
func _engine(parent: Node, pos: Vector3, s: float) -> void:
	var e := Node3D.new(); e.position = pos; parent.add_child(e); engines.append(e)
	var dark := U.mat(Color(0.22, 0.22, 0.23), 0.5, 0.8, 1.2)
	var gold := U.mat(Color(0.72, 0.55, 0.28), 0.35, 0.9)
	var bellm := U.shader_mat("res://shaders/bell.gdshader", {"len": 1.9 * s, "tubes": 150.0})
	# combustion chamber + throat + bell (bell hangs below the stage)
	U.put(e, U.lathe(PackedVector2Array([Vector2(0.17 * s, 0.3), Vector2(0.27 * s, 0.05), Vector2(0.27 * s, -0.35), Vector2(0.16 * s, -0.62)]), 32), dark)
	var bp := U.bell_prof(0.16 * s, 0.62 * s, 1.9 * s, -0.62)
	U.put(e, U.lathe(bp, 48), bellm)
	U.put(e, U.lathe(PackedVector2Array([Vector2(0.62 * s, -2.52 * s), Vector2(0.645 * s, -2.5 * s), Vector2(0.645 * s, -2.42 * s), Vector2(0.62 * s, -2.42 * s)]), 48), dark)
	# turbopump and ducts on the side
	U.cyl(e, 0.13 * s, 0.13 * s, 0.5 * s, Vector3(0.42 * s, -0.1, 0), dark, 16)
	U.cyl(e, 0.09 * s, 0.11 * s, 0.25 * s, Vector3(0.42 * s, -0.48 * s, 0), gold, 16)
	U.beam(e, Vector3(0.42 * s, 0.15, 0), Vector3(0.15 * s, 0.35, 0.1), 0.05 * s, dark)
	U.beam(e, Vector3(0.42 * s, -0.3, 0), Vector3(0.24 * s, -0.2, -0.12), 0.045 * s, gold)
	U.beam(e, Vector3(0.42 * s, -0.6 * s, 0), Vector3(0.55 * s, -1.2 * s, 0.1), 0.06 * s, dark)   # turbine exhaust duct
	# gimbal actuators
	for k in 2:
		var a := PI * 0.5 * k
		U.beam(e, Vector3(sin(a), 0, cos(a)) * 0.35 + Vector3(0, 0.45, 0), Vector3(sin(a), 0, cos(a)) * 0.3 + Vector3(0, -0.4, 0), 0.04, U.mat(Color(0.7, 0.7, 0.72), 0.3, 0.9))
	var pp := Node3D.new(); pp.position = Vector3(0, -2.5 * s, 0); e.add_child(pp); plume_points.append(pp)

# ---------- boosters ----------
func _booster(i: int) -> void:
	var a := TAU * i / 4.0 + PI / 4.0
	var b := Node3D.new(); b.name = "Booster%d" % i; b.position = Vector3(sin(a), 0, cos(a)) * (R_CORE + R_BST + 0.08); b.rotation.y = a
	stage1.add_child(b); boosters.append(b)
	var m := _skin({"soot": 0.7, "seams": 12.0})
	_lathe(b, PackedVector2Array([Vector2(R_BST + 0.1, 0.0), Vector2(R_BST, 0.7), Vector2(R_BST, 15.3)]), m, 56)
	_lathe(b, U.nose_prof(R_BST, 15.3, 4.4, 18), _skin({"seams": 8.0}), 56)
	var ringm := U.mat(Color(0.78, 0.78, 0.76), 0.5, 0.3)
	for y in [0.7, 7.6, 15.3]:
		_lathe(b, PackedVector2Array([Vector2(R_BST + 0.02, y - 0.06), Vector2(R_BST + 0.035, y), Vector2(R_BST + 0.02, y + 0.06)]), ringm, 48)
	# stabilising fins (CZ-2 boosters carry big trapezoid fins)
	var finm := _skin({"seams": 2.0, "ring_m": 10.0})
	var fin := U.box(b, Vector3(0.08, 3.2, 2.0), Vector3(0, 1.9, R_BST + 0.95), finm)
	var fin2 := U.box(b, Vector3(0.1, 1.2, 0.7), Vector3(0, 0.75, R_BST + 2.1), finm)
	_engine(b, Vector3(0, 0.2, 0), 0.92)

# ---------- interstage (open truss: stage-2 engine visible, as on the real vehicle) ----------
func _interstage() -> void:
	var steel := U.mat(Color(0.34, 0.35, 0.37), 0.45, 0.7, 1.0)
	var segs := []
	var n := 24
	for i in n:
		var a0 := TAU * i / n; var a1 := TAU * (i + 1) / n
		var p0 := Vector3(sin(a0) * R_CORE * 0.98, Y_S1_TOP, cos(a0) * R_CORE * 0.98)
		var p1 := Vector3(sin(a1) * R_CORE * 0.98, Y_S2_BOT, cos(a1) * R_CORE * 0.98)
		var p2 := Vector3(sin(a0) * R_CORE * 0.98, Y_S2_BOT, cos(a0) * R_CORE * 0.98)
		segs.append([p0, p1]); segs.append([p2, Vector3(sin(a1) * R_CORE * 0.98, Y_S1_TOP, cos(a1) * R_CORE * 0.98)])
	U.struts(stage1, segs, 0.07, steel, false)
	for y in [Y_S1_TOP + 0.05, Y_S2_BOT - 0.05]:
		U.put(stage1, U.lathe(PackedVector2Array([Vector2(R_CORE, y - 0.1), Vector2(R_CORE + 0.03, y), Vector2(R_CORE, y + 0.1)]), 64), steel)
	U.cyl(stage1, R_CORE, R_CORE, 0.05, Vector3(0, Y_S1_TOP, 0), U.mat(Color(0.5, 0.5, 0.5), 0.6, 0.4), 48)  # stage-1 forward dome cap

# ---------- second stage ----------
func _second_stage() -> void:
	var m := _skin({})
	_lathe(stage2, PackedVector2Array([Vector2(R_CORE, Y_S2_BOT), Vector2(R_CORE, Y_S2_TOP)]), m)
	U.put(stage2, U.lathe(PackedVector2Array([Vector2(0.0, Y_S2_BOT - 0.55), Vector2(R_CORE * 0.7, Y_S2_BOT - 0.35), Vector2(R_CORE, Y_S2_BOT)]), 48), U.mat(Color(0.5, 0.5, 0.52), 0.5, 0.6))
	_engine(stage2, Vector3(0, Y_S2_BOT - 0.4, 0), 1.0)
	for k in 4:   # vernier engines
		var a := TAU * k / 4.0
		_engine(stage2, Vector3(sin(a) * 1.25, Y_S2_BOT - 0.2, cos(a) * 1.25), 0.35)

# ---------- spacecraft stack inside the fairing: adapter, service module, (capsule from capsule.gd), orbital module ----------
var ship_om: Node3D
func _spacecraft() -> void:
	var y0 := Y_S2_TOP; var ysm := y_cap - 0.34
	var alu := U.mat(Color(0.72, 0.72, 0.7), 0.45, 0.6)
	# payload adapter cone on top of stage 2 (separates with it)
	U.put(stage2, U.lathe(PackedVector2Array([Vector2(R_CORE, y0), Vector2(1.55, y0 + 0.45), Vector2(1.42, y0 + 0.6)]), 64), U.mat(Color(0.88, 0.88, 0.86), 0.6, 0.1))
	U.put(stage2, U.lathe(PackedVector2Array([Vector2(0.0, y0 + 0.02), Vector2(R_CORE - 0.02, y0 + 0.02)]), 48), alu)
	# service module: radiator-banded cylinder + aft skirt, folded arrays, RCS quads; tagged "sa" so it drops at SM sep
	var sm := Node3D.new(); sm.set_meta("sa", true); add_child(sm)
	var rad := U.mat(Color(0.93, 0.93, 0.9), 0.35, 0.05)
	var dark := U.mat(Color(0.2, 0.2, 0.22), 0.6, 0.5)
	U.put(sm, U.lathe(PackedVector2Array([Vector2(1.42, y0 + 0.6), Vector2(1.42, y0 + 1.05), Vector2(1.36, y0 + 1.1), Vector2(1.36, ysm - 0.15), Vector2(1.25, ysm), Vector2(0.9, ysm + 0.02)]), 72), rad)
	for k in 3: U.put(sm, U.lathe(PackedVector2Array([Vector2(1.37, y0 + 1.4 + k * 0.6), Vector2(1.385, y0 + 1.43 + k * 0.6), Vector2(1.37, y0 + 1.46 + k * 0.6)]), 72), dark)
	for k in 4:
		var a := TAU * k / 4.0 + PI / 4.0
		var d := Vector3(sin(a), 0, cos(a))
		U.box(sm, Vector3(0.18, 0.18, 0.12), d * 1.42 + Vector3(0, ysm - 0.5, 0), dark, Vector3(0, a, 0))
		for j in 4: U.cyl(sm, 0.025, 0.04, 0.08, d * 1.5 + Vector3(0, ysm - 0.5 + (j - 1.5) * 0.06, 0), dark, 10, Vector3(0, 0, PI * 0.5))
	for s in [-1, 1]:   # stowed solar array packs
		U.box(sm, Vector3(0.12, 2.0, 0.9), Vector3(s * 1.46, y0 + 1.15 + 1.0, 0), U.mat(Color(0.1, 0.12, 0.25), 0.3, 0.5))
	# main engine bells under the SM (inside adapter)
	for k in 4:
		var a := TAU * k / 4.0
		U.put(sm, U.lathe(PackedVector2Array([Vector2(0.08, y0 + 0.95), Vector2(0.18, y0 + 0.7)]), 24, 0.0, TAU, true), dark).position = Vector3(sin(a) * 0.5, 0, cos(a) * 0.5)
	# orbital module shell above the capsule (orbit.gd builds the interior version)
	ship_om = Node3D.new(); ship_om.position.y = y_cap + 2.25; add_child(ship_om)
	var prof := PackedVector2Array([Vector2(0.45, 0.0), Vector2(1.0, 0.3), Vector2(1.12, 1.0), Vector2(1.1, 1.9), Vector2(0.85, 2.5), Vector2(0.45, 2.75)])
	var outer := PackedVector2Array(); for p in prof: outer.append(p + Vector2(0.08, 0))
	U.put(ship_om, U.lathe(outer, 64), U.mat(Color(0.86, 0.86, 0.82), 0.7, 0.05, 1.5))
	U.cyl(ship_om, 0.55, 0.45, 0.3, Vector3(0, -0.05, 0), alu, 48)   # tunnel ring to capsule hatch
	U.cyl(ship_om, 0.42, 0.42, 0.25, Vector3(0, 2.85, 0), alu, 48)   # docking ring

# ---------- fairing over the spacecraft ----------
func _fairing() -> void:
	fairing = Node3D.new(); fairing.name = "Fairing"; add_child(fairing)
	var m := _skin({"seams": 2.0, "ring_m": 3.2, "grime": 0.18})
	var prof := PackedVector2Array([Vector2(R_CORE, Y_FAIR_BOT), Vector2(R_FAIR, Y_FAIR_BOT + 1.4), Vector2(R_FAIR, Y_FAIR_CYL)])
	var nose := U.nose_prof(R_FAIR, Y_FAIR_CYL, Y_FAIR_TOP - Y_FAIR_CYL + 1.2, 16, 0.3)
	for i in range(1, nose.size()):
		if nose[i].y <= Y_FAIR_TOP: prof.append(nose[i])
	prof.append(Vector2(0.42, Y_FAIR_TOP))
	_lathe(fairing, prof, m, 96)
	# separation seam (two halves) and crew access hatch facing the tower (-x)
	var seam := U.mat(Color(0.15, 0.15, 0.15), 0.7)
	for a in [PI * 0.5, PI * 1.5]:
		U.box(fairing, Vector3(0.03, Y_FAIR_CYL - Y_FAIR_BOT - 1.4, 0.03), Vector3(sin(a) * (R_FAIR + 0.005), (Y_FAIR_BOT + 1.4 + Y_FAIR_CYL) * 0.5, cos(a) * (R_FAIR + 0.005)), seam)
	var hatch := U.mat(Color(0.86, 0.86, 0.83), 0.5)
	var hz := Node3D.new(); hz.position = Vector3(-R_FAIR - 0.01, Y_CAPSULE + 1.0, 0); hz.rotation.y = -PI * 0.5; fairing.add_child(hz)
	U.box(hz, Vector3(1.0, 1.2, 0.04), Vector3.ZERO, hatch)
	for p in [Vector3(-0.52, 0, 0), Vector3(0.52, 0, 0), Vector3(0, 0.62, 0), Vector3(0, -0.62, 0)]:
		U.box(hz, Vector3(0.04 if p.x != 0.0 else 1.08, 0.04 if p.x == 0.0 else 1.28, 0.05), p, seam)
	# grid fins at the top of the fairing (escape stabilisers)
	var gm := U.mat(Color(0.42, 0.43, 0.45), 0.45, 0.75)
	for k in 4:
		var a := TAU * k / 4.0 + PI / 4.0
		var g := Node3D.new(); g.position = Vector3(sin(a) * (R_FAIR + 0.35), Y_FAIR_CYL - 0.6, cos(a) * (R_FAIR + 0.35)); g.rotation.y = a; fairing.add_child(g)
		var segs := []
		for j in 7:
			var t := -0.45 + j * 0.15
			segs.append([Vector3(-0.45, t, 0), Vector3(0.45, t, 0)]); segs.append([Vector3(t, -0.45, 0), Vector3(t, 0.45, 0)])
		var mmi := U.struts(g, segs, 0.025, gm)
		mmi.rotation.z = PI * 0.25
		U.box(g, Vector3(0.95, 0.05, 0.35), Vector3(0, -0.5, 0), gm); U.box(g, Vector3(0.95, 0.05, 0.35), Vector3(0, 0.5, 0), gm)
		U.beam(g, Vector3(0, -0.5, -0.05), Vector3(0, -0.4, -0.35), 0.03, gm)

# ---------- launch escape tower ----------
func _les() -> void:
	les = Node3D.new(); les.name = "LES"; add_child(les)
	var steel := U.mat(Color(0.3, 0.31, 0.33), 0.4, 0.75)
	var mot := _skin({"seams": 6.0, "ring_m": 1.2, "grime": 0.4})
	# lattice adapter
	var segs := []; var y0 := Y_FAIR_TOP; var y1 := Y_FAIR_TOP + 2.2
	for i in 6:
		var a0 := TAU * i / 6.0; var a1 := TAU * (i + 1) / 6.0
		segs.append([Vector3(sin(a0) * 0.42, y0, cos(a0) * 0.42), Vector3(sin(a1) * 0.28, y1, cos(a1) * 0.28)])
		segs.append([Vector3(sin(a1) * 0.42, y0, cos(a1) * 0.42), Vector3(sin(a0) * 0.28, y1, cos(a0) * 0.28)])
		segs.append([Vector3(sin(a0) * 0.42, y0, cos(a0) * 0.42), Vector3(sin(a0) * 0.28, y1, cos(a0) * 0.28)])
	U.struts(les, segs, 0.05, steel, false)
	# escape motor with canted nozzles, separation motor, pointed nose
	_lathe(les, PackedVector2Array([Vector2(0.32, y1), Vector2(0.32, y1 + 3.6)]), mot, 32)
	_lathe(les, U.nose_prof(0.32, y1 + 3.6, Y_LES_TOP - y1 - 3.6, 12), mot, 32)
	var noz := U.mat(Color(0.2, 0.2, 0.21), 0.5, 0.8)
	for k in 4:
		var a := TAU * k / 4.0
		var n := U.put(les, U.lathe(U.bell_prof(0.05, 0.13, 0.32, 0.0, 6), 16), noz)
		n.transform = Transform3D(U.basis_from_y(Vector3(sin(a) * 0.7, 1.0, cos(a) * 0.7)).rotated(Vector3.UP, 0.0), Vector3(sin(a) * 0.3, y1 + 0.5, cos(a) * 0.3))
		n.transform.basis = n.transform.basis * Basis(Vector3.RIGHT, PI)
	_lathe(les, PackedVector2Array([Vector2(0.33, y1 + 2.4), Vector2(0.36, y1 + 2.5), Vector2(0.36, y1 + 2.8), Vector2(0.33, y1 + 2.9)]), steel, 32)

# ---------- paint & markings ----------
func _markings() -> void:
	var red := Color(0.78, 0.08, 0.06); var blk := Color(0.08, 0.08, 0.08)
	# vertical "中国航天" on the core facing the camera side (+z) and the flag
	var l := U.label(stage1, "中\n国\n航\n天", Vector3(0, 20.0, R_CORE + 0.01), 0.75, red)
	l.line_spacing = 18
	var f := U.label(stage1, "启航", Vector3(0, 9.0, R_CORE + 0.01), 0.55, blk)
	var flag := MeshInstance3D.new(); var q := QuadMesh.new(); q.size = Vector2(1.5, 1.0); flag.mesh = q
	var fm := StandardMaterial3D.new(); fm.albedo_texture = _flag_tex(); fm.roughness = 0.5; flag.material_override = fm
	flag.position = Vector3(0, 50.4, R_FAIR + 0.012); fairing.add_child(flag)
	var cz := U.label(fairing, "启 航 号", Vector3(0, 48.0, R_FAIR + 0.012), 0.48, red)
	U.label(stage2, "QH-2F", Vector3(0, 37.0, R_CORE + 0.01), 0.42, blk)

func _flag_tex() -> ImageTexture:
	var img := Image.create(300, 200, false, Image.FORMAT_RGBA8); img.fill(Color(0.87, 0.1, 0.07))
	var star := func(cx: float, cy: float, r: float):
		for y in range(int(cy - r), int(cy + r) + 1):
			for x in range(int(cx - r), int(cx + r) + 1):
				var dx := x - cx; var dy := y - cy; var ang := atan2(dy, dx) + PI / 2.0; var d := sqrt(dx * dx + dy * dy)
				var k := fmod(ang + TAU * 10.0, TAU / 5.0) / (TAU / 5.0)
				var lim := r * lerpf(0.38, 1.0, absf(k - 0.5) * 2.0)
				if d < lim * 0.95 and x >= 0 and y >= 0 and x < 300 and y < 200: img.set_pixel(x, y, Color(1.0, 0.87, 0.0))
	star.call(50.0, 50.0, 30.0)
	for p in [Vector2(100, 20), Vector2(120, 40), Vector2(120, 70), Vector2(100, 90)]: star.call(p.x, p.y, 10.0)
	return ImageTexture.create_from_image(img)

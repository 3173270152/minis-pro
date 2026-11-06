## Exterior builders for the other vehicles, filling the Rocket interface (stage1, stage2, boosters, fairing, les,
## plume_points, y_cap, r_hatch, top, cab, land, events). Real dimensions; materials reuse the skin shader.
class_name RV
extends RefCounted

static func build(r: Rocket) -> void:
	match r.kind:
		"saturn": _saturn(r)
		"fh": _fh(r)
		"shuttle": _shuttle(r)

static func _skin(r: Rocket, base: Color, p := {}) -> ShaderMaterial:
	var m: ShaderMaterial = r.skin_white.duplicate(); m.set_shader_parameter("base", base)
	for k in p: m.set_shader_parameter(k, p[k])
	return m

static func _lathe(parent: Node, prof: PackedVector2Array, m: Material, seg := 72) -> MeshInstance3D:
	return U.put(parent, U.lathe(prof, seg), m)

static func _engines(r: Rocket, parent: Node3D, pts: Array, s: float, y: float) -> void:
	for p in pts: r._engine(parent, Vector3(p.x, y, p.y), s)

## Saturn V / Apollo: S-IC 10.1 m x 42 m (5 F-1), S-II 25 m (5 J-2), S-IVB 6.6 m, IU, SLA, SM, CM, LES
static func _saturn(r: Rocket) -> void:
	var W := Color(0.94, 0.94, 0.92); var K := Color(0.08, 0.08, 0.08)
	var R1 := 5.05
	r.y_cap = 99.4; r.r_hatch = 1.95; r.top = 110.6; r.cab = "apollo"; r.land = "sea"
	var s1 := r.stage1
	_lathe(s1, PackedVector2Array([Vector2(R1 + 0.25, 0.0), Vector2(R1, 1.5), Vector2(R1, 42.0)]), _skin(r, W, {"seams": 8.0, "ring_m": 3.0, "soot": 0.4}), 96)
	# black roll-pattern panels and the black upper band (as flown)
	var km := U.mat(K, 0.6)
	for a in [0.0, PI]:
		U.box(s1, Vector3(3.2, 6.0, 0.05), Vector3(sin(a) * (R1 + 0.02), 33.0, cos(a) * (R1 + 0.02)), km, Vector3(0, a, 0))
		U.box(s1, Vector3(3.2, 9.0, 0.05), Vector3(sin(a + PI * 0.5) * (R1 + 0.02), 6.0, cos(a + PI * 0.5) * (R1 + 0.02)), km, Vector3(0, a + PI * 0.5, 0))
	U.cyl(s1, R1 + 0.02, R1 + 0.02, 1.2, Vector3(0, 41.0, 0), km, 96)
	U.label(s1, "U\nS\nA", Vector3(0, 22.0, R1 + 0.03), 2.0, K).line_spacing = 30
	U.label(s1, "UNITED STATES", Vector3(R1 + 0.03, 25.0, 0), 1.2, Color(0.1, 0.1, 0.1), Vector3(0, PI * 0.5, PI * 0.5))
	for k in 4:   # fins + engine fairings
		var a := TAU * k / 4.0 + PI * 0.25; var d := Vector3(sin(a), 0, cos(a))
		var fin := U.box(s1, Vector3(0.35, 6.0, 3.5), d * (R1 + 1.6) + Vector3(0, 3.0, 0), _skin(r, W), Vector3(0, a, 0))
		U.put(s1, U.lathe(U.nose_prof(1.15, 1.5, 7.0, 10, 0.5), 24), _skin(r, W)).position = d * (R1 - 0.6)
	var f1 := [Vector2(0, 0), Vector2(2.4, 2.4), Vector2(-2.4, 2.4), Vector2(2.4, -2.4), Vector2(-2.4, -2.4)]
	_engines(r, s1, f1, 2.6, 0.6)
	# S-II and S-IVB
	var s2 := r.stage2
	_lathe(s1, PackedVector2Array([Vector2(R1, 42.0), Vector2(R1, 47.0)]), _skin(r, W, {"seams": 16.0}), 96)   # interstage
	_lathe(s2, PackedVector2Array([Vector2(R1, 47.0), Vector2(R1, 67.0), Vector2(3.3, 71.0)]), _skin(r, W, {"seams": 12.0, "ring_m": 2.5}), 96)
	U.cyl(s2, R1 + 0.02, R1 + 0.02, 1.0, Vector3(0, 66.5, 0), km, 96)
	_lathe(s2, PackedVector2Array([Vector2(3.3, 71.0), Vector2(3.3, 88.0)]), _skin(r, W, {"seams": 10.0}), 72)
	U.box(s2, Vector3(1.6, 2.2, 0.04), Vector3(0, 80.0, 3.31), km)
	U.cyl(s2, 3.32, 3.32, 0.9, Vector3(0, 88.45, 0), U.mat(Color(0.75, 0.75, 0.72), 0.5, 0.4), 72)   # instrument unit
	_engines(r, s2, [Vector2(0, 0), Vector2(1.6, 1.6), Vector2(-1.6, 1.6), Vector2(1.6, -1.6), Vector2(-1.6, -1.6)], 1.0, 46.6)
	# SLA (cone) -> service module -> command module under the boost protective cover + LES tower
	r.fairing = Node3D.new(); r.add_child(r.fairing)
	_lathe(r.fairing, PackedVector2Array([Vector2(3.3, 88.9), Vector2(1.96, 97.4)]), _skin(r, W, {"seams": 4.0}), 72)
	_lathe(r, PackedVector2Array([Vector2(1.96, 97.4), Vector2(1.96, 99.4)]), U.mat(Color(0.82, 0.82, 0.8), 0.3, 0.6), 64)   # SM (polished panels)
	r.les = Node3D.new(); r.add_child(r.les)
	_lathe(r.les, PackedVector2Array([Vector2(1.98, 99.4), Vector2(1.6, 100.0), Vector2(0.55, 102.6), Vector2(0.2, 103.0)]), _skin(r, W, {"seams": 1.0}), 48)   # BPC
	var steel := U.mat(Color(0.75, 0.2, 0.1), 0.5, 0.5)
	var segs := []
	for k in 4:
		var a := TAU * k / 4.0
		segs.append([Vector3(sin(a) * 1.3, 100.0, cos(a) * 1.3), Vector3(sin(a) * 0.4, 104.0, cos(a) * 0.4)])
	U.struts(r.les, segs, 0.12, steel, false)
	_lathe(r.les, PackedVector2Array([Vector2(0.33, 104.0), Vector2(0.33, 108.5)]), _skin(r, W), 24)
	_lathe(r.les, U.nose_prof(0.33, 108.5, 2.1, 10), U.mat(Color(0.7, 0.1, 0.08), 0.5), 24)
	r.events = [[12.0, "tower", "程序转弯"], [66.0, "mach", "突破音速"], [83.0, "maxq", "最大动压"], [162.0, "meco", "一级关机"], [164.0, "sep", "一二级分离"], [192.0, "lesj", "逃逸塔分离"], [495.0, "seco", "二级关机"], [700.0, "shipsep", "入轨"]]

## Falcon Heavy + Crew Dragon: three 3.66 m cores (9 Merlins each), black interstage, grid fins, legs, Dragon + trunk
static func _fh(r: Rocket) -> void:
	var W := Color(0.95, 0.95, 0.94); var K := Color(0.07, 0.07, 0.08)
	var Rc := 1.83
	r.y_cap = 63.6; r.r_hatch = 1.95; r.top = 70.0; r.cab = "dragon"; r.land = "sea"; r.has_les = false
	var oct := []
	oct.append(Vector2.ZERO)
	for k in 8: oct.append(Vector2(sin(TAU * k / 8.0), cos(TAU * k / 8.0)) * 1.1)
	var core := func(parent: Node3D, h: float, nose: bool) -> void:
		_lathe(parent, PackedVector2Array([Vector2(Rc, 0.0), Vector2(Rc, h)]), _skin(r, W, {"seams": 6.0, "ring_m": 3.6, "soot": 0.8}), 64)
		U.cyl(parent, Rc + 0.02, Rc + 0.02, 1.6, Vector3(0, 0.8, 0), U.mat(Color(0.2, 0.2, 0.22), 0.6, 0.5), 64)     # octaweb skirt
		for k in 4:   # landing legs folded, grid fins stowed
			var a := TAU * k / 4.0 + PI * 0.25; var d := Vector3(sin(a), 0, cos(a))
			U.box(parent, Vector3(0.6, 9.0, 0.25), d * (Rc + 0.14) + Vector3(0, 5.0, 0), U.mat(K, 0.6, 0.3), Vector3(0, a, 0))
			U.box(parent, Vector3(1.2, 0.08, 1.4), d * (Rc + 0.25) + Vector3(0, h - 1.5, 0), U.mat(Color(0.25, 0.25, 0.27), 0.5, 0.7), Vector3(0, a, 0))
		if nose: _lathe(parent, U.nose_prof(Rc, h, 5.5, 14, 0.2), _skin(r, W, {"seams": 4.0}), 64)
		_engines(r, parent, oct, 0.55, 0.3)
	var s1 := r.stage1
	core.call(s1, 42.6, false)
	for s in [-1, 1]:
		var b := Node3D.new(); b.position = Vector3(0, 0, s * (Rc * 2.0 + 0.3)); s1.add_child(b); r.boosters.append(b)
		core.call(b, 42.6, true)
		U.beam(b, Vector3(0, 40.0, -s * Rc), Vector3(0, 40.0, -s * (Rc + 0.3)), 0.2, U.mat(Color(0.3, 0.3, 0.3), 0.5, 0.7))
	U.cyl(s1, Rc + 0.01, Rc + 0.01, 4.4, Vector3(0, 44.8, 0), U.mat(K, 0.55, 0.3), 64)   # black interstage
	var s2 := r.stage2
	_lathe(s2, PackedVector2Array([Vector2(Rc, 47.0), Vector2(Rc, 60.0)]), _skin(r, W, {"seams": 4.0, "ring_m": 4.0}), 64)
	_engines(r, s2, [Vector2.ZERO], 1.6, 46.8)
	U.label(s1, "FALCON HEAVY", Vector3(0, 26.0, Rc + 0.01), 1.2, Color(0.1, 0.1, 0.12), Vector3(0, 0, PI * 0.5))
	# trunk with solar cells + Dragon capsule with nose cap; Dragon's SuperDraco escape uses the capsule itself
	r.fairing = Node3D.new(); r.add_child(r.fairing)
	_lathe(r.fairing, PackedVector2Array([Vector2(Rc, 60.0), Vector2(Rc, 63.6)]), U.mat(Color(0.12, 0.13, 0.22), 0.3, 0.6), 64)
	_lathe(r, PackedVector2Array([Vector2(1.95, 63.6), Vector2(1.9, 64.2), Vector2(1.3, 67.3), Vector2(0.85, 67.8)]), _skin(r, W, {"seams": 1.0}), 64)
	r.les = Node3D.new(); r.add_child(r.les)
	_lathe(r.les, PackedVector2Array([Vector2(0.85, 67.8), Vector2(0.75, 68.6), Vector2(0.0, 69.2)]), _skin(r, W), 32)
	for k in 4:
		var a := TAU * k / 4.0
		U.box(r, Vector3(0.6, 0.9, 0.2), Vector3(sin(a) * 1.6, 65.2, cos(a) * 1.6), U.mat(K, 0.5), Vector3(-0.35, a, 0))
	U.label(r, "DRAGON", Vector3(0, 65.5, 1.75), 0.45, Color(0.1, 0.1, 0.12), Vector3(-0.5, 0, 0))
	r.events = [[10.0, "tower", "程序转弯"], [64.0, "mach", "突破音速"], [72.0, "maxq", "最大动压"], [154.0, "bsep", "侧助推器分离"], [184.0, "meco", "芯级关机"], [187.0, "sep", "一二级分离"], [520.0, "seco", "二级关机"], [540.0, "shipsep", "龙飞船分离"]]

## Space Shuttle stack: orange ET (8.4 m), two SRBs (3.7 m), orbiter on the ET's -X side with the crew cabin near the nose
static func _shuttle(r: Rocket) -> void:
	var O := Color(0.72, 0.36, 0.15); var W := Color(0.94, 0.94, 0.92); var K := Color(0.08, 0.08, 0.09)
	r.cab = "shuttle"; r.land = "runway"; r.has_les = false
	var s1 := r.stage1   # SRBs + ET + SSMEs on the orbiter count as the "core"
	_lathe(s1, PackedVector2Array([Vector2(4.2, 4.0), Vector2(4.2, 40.0)]), _skin(r, O, {"seams": 1.0, "ring_m": 6.0, "grime": 0.5}), 96)
	_lathe(s1, U.nose_prof(4.2, 40.0, 7.0, 16, 0.08), _skin(r, O, {"grime": 0.5}), 96)
	_lathe(s1, PackedVector2Array([Vector2(0.0, 2.0), Vector2(3.6, 3.0), Vector2(4.2, 4.0)]), _skin(r, O), 64)
	for s in [-1, 1]:
		var b := Node3D.new(); b.position = Vector3(0, 0, s * 6.45); s1.add_child(b); r.boosters.append(b)
		_lathe(b, PackedVector2Array([Vector2(2.6, 0.0), Vector2(1.85, 3.0), Vector2(1.85, 42.0)]), _skin(r, W, {"seams": 1.0, "ring_m": 3.5, "soot": 0.6}), 48)
		_lathe(b, U.nose_prof(1.85, 42.0, 5.0, 12), _skin(r, W), 48)
		r._engine(b, Vector3(0, 0.4, 0), 1.35)
	# orbiter
	var orb := Node3D.new(); orb.position = Vector3(-6.3, 0, 0); r.add_child(orb); r.stage2 = orb
	var tile := _skin(r, W, {"seams": 30.0, "ring_m": 0.6, "grime": 0.3})
	_lathe(orb, PackedVector2Array([Vector2(2.6, 3.0), Vector2(2.6, 30.0), Vector2(2.4, 33.5), Vector2(1.9, 35.8), Vector2(1.1, 37.4), Vector2(0.0, 38.2)]), tile, 48)
	var black := U.mat(K, 0.7, 0.1, 1.5)
	U.box(orb, Vector3(0.5, 30.0, 5.2), Vector3(2.4, 18.0, 0), black)    # black belly tiles facing the ET
	for s in [-1, 1]:
		var wing := MeshInstance3D.new(); var pm := PrismMesh.new(); pm.size = Vector3(12.0, 18.0, 0.6); pm.left_to_right = 0.0 if s > 0 else 1.0
		wing.mesh = pm; wing.material_override = tile; orb.add_child(wing); wing.position = Vector3(0.8, 12.0, s * 7.5); wing.rotation = Vector3(PI * 0.5, 0, 0)
		U.box(orb, Vector3(0.3, 16.0, 11.0), Vector3(2.2, 11.5, s * 7.3), black)
		U.rbox(orb, Vector3(2.0, 5.5, 1.8), 0.6, Vector3(-1.4, 5.0, s * 1.8), tile)    # OMS pods
	U.box(orb, Vector3(8.0, 0.5, 0.4), Vector3(-4.2, 6.0, 0), tile, Vector3(0, 0, -0.45))   # vertical stabiliser
	for p in [Vector2(-1.2, 0.0), Vector2(0.4, 1.2), Vector2(0.4, -1.2)]: r._engine(orb, Vector3(p.x, 3.0, p.y), 1.25)
	U.label(orb, "UNITED STATES", Vector3(-2.61, 22.0, 0), 1.0, K, Vector3(0, -PI * 0.5, PI * 0.5))
	r.fairing = Node3D.new(); r.add_child(r.fairing); r.les = Node3D.new(); r.add_child(r.les)
	r.y_cap = 33.0; r.r_hatch = 2.5; r.top = 47.0
	r.events = [[10.0, "tower", "程序转弯"], [52.0, "maxq", "最大动压"], [64.0, "mach", "突破音速"], [124.0, "bsep", "固体助推器分离"], [510.0, "meco", "主发动机关机"], [528.0, "seco", "外挂燃料箱分离"], [540.0, "shipsep", "入轨"]]

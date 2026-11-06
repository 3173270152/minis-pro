## Shenzhou-style descent module, interior first.
## Frame: origin = centre of the heat-shield floor, +Y = up the rocket axis, crew lie on their backs with heads toward +X,
## looking up (+Y) and slightly toward their feet (-X). Seats across Z: left -0.62, centre 0 (commander / player), right +0.62.
class_name Capsule
extends Node3D

const H := 2.2
const EYE := Vector3(0.36, 0.66, 0.0)           # player's eye in capsule space
const PANEL_POS := Vector3(-0.15, 1.25, 0.0)    # main instrument panel centre
var seat_anchor: Node3D
var panel_root: Node3D        # main panel frame: +Z faces the crew, +X to their right, +Y toward their heads
var side_l: Node3D
var side_r: Node3D
var hatch: Node3D
var lights: Array[Light3D] = []
var crew: Array[Node3D] = []
var screens: Array = []
var variant := "shenzhou"   # shenzhou / apollo / dragon / shuttle

var m_fab: ShaderMaterial
var m_frame: StandardMaterial3D
var m_dark: StandardMaterial3D
var m_alu: StandardMaterial3D
var m_suit: StandardMaterial3D
var m_seat: StandardMaterial3D
var m_cush: StandardMaterial3D

func inner_r(y: float) -> float:
	# bell-shaped inner wall (lining surface)
	var pts := [[0.0, 1.12], [0.25, 1.16], [0.6, 1.13], [1.0, 1.02], [1.4, 0.86], [1.8, 0.66], [2.05, 0.5], [2.2, 0.42]]
	for i in pts.size() - 1:
		if y <= pts[i + 1][0]:
			var t: float = (y - pts[i][0]) / (pts[i + 1][0] - pts[i][0])
			return lerpf(pts[i][1], pts[i + 1][1], smoothstep(0.0, 1.0, t))
	return 0.42

func _ready() -> void:
	var lin: Color = {"apollo": Color(0.74, 0.75, 0.7), "dragon": Color(0.93, 0.93, 0.92), "shuttle": Color(0.8, 0.78, 0.72)}.get(variant, Color(0.86, 0.8, 0.66))
	m_fab = U.shader_mat("res://shaders/quilt.gdshader", {"nz": U.noise_tex(0.03, false, 61, 256, 4), "base": lin})
	m_frame = U.mat(Color(0.36, 0.38, 0.4), 0.45, 0.6, 1.0)
	m_dark = U.mat(Color(0.12, 0.13, 0.14), 0.55, 0.4, 0.8)
	m_alu = U.mat(Color(0.75, 0.76, 0.78), 0.32, 0.85, 0.6)
	m_suit = U.mat(Color(0.9, 0.9, 0.87), 0.85, 0.0, 1.5)
	m_seat = U.mat(Color(0.08, 0.08, 0.09) if variant == "dragon" else Color(0.28, 0.3, 0.32), 0.5, 0.3, 1.0)
	m_cush = U.mat(Color(0.86, 0.85, 0.8), 0.95, 0.0, 2.5)
	_shell()
	_floor_and_frames()
	for i in 3: _seat(Vector3(0, 0, (i - 1) * 0.62), i == 1)
	_main_panel()
	_side_panels()
	_windows()
	_hatch()
	_details()
	_lighting()
	seat_anchor = Node3D.new(); seat_anchor.position = EYE; add_child(seat_anchor)
	# look direction: up and toward the feet / panel
	U.aim(seat_anchor, EYE, PANEL_POS + Vector3(0, -0.05, 0), Vector3(1, 0, 0))

func _shell() -> void:
	var prof := PackedVector2Array()
	for i in 23:
		var y := 0.02 + (H - 0.04) * i / 22.0
		prof.append(Vector2(inner_r(y), y))
	U.put(self, U.lathe(prof, 96, 0.0, TAU, true), m_fab)
	# outer pressure hull + heat shield seen from outside (inside the fairing / in orbit)
	var outer := PackedVector2Array()
	for i in 23:
		var y := (H + 0.05) * i / 22.0
		outer.append(Vector2(inner_r(y) + 0.12 + 0.02 * sin(y * 3.0), y))
	var om := U.mat(Color(0.86, 0.86, 0.82), 0.7, 0.05, 1.5); om.cull_mode = BaseMaterial3D.CULL_DISABLED
	U.put(self, U.lathe(outer, 96), om)
	U.put(self, U.lathe(PackedVector2Array([Vector2(0.0, -0.32), Vector2(0.7, -0.27), Vector2(1.2, -0.12), Vector2(1.3, 0.0)]), 96), U.tri_mat(Color(0.32, 0.22, 0.14), 0.9, 0.0, 6.0, 4.0))

func _floor_and_frames() -> void:
	# metal floor plate under the seats, longerons and ring frames showing through the lining
	U.cyl(self, 1.1, 1.1, 0.04, Vector3(0, 0.02, 0), m_frame, 64)
	for y in [0.55, 1.15, 1.7]:
		var r := inner_r(y) - 0.015
		U.put(self, U.lathe(PackedVector2Array([Vector2(r, y - 0.03), Vector2(r - 0.025, y), Vector2(r, y + 0.03)]), 96, 0.0, TAU, true), m_frame)
	var segs := []
	for k in 12:
		var a := TAU * k / 12.0
		var pts := []
		for j in 8:
			var y := 0.1 + j * 0.27
			pts.append(Vector3(sin(a) * (inner_r(y) - 0.012), y, cos(a) * (inner_r(y) - 0.012)))
		for j in 7: segs.append([pts[j], pts[j + 1]])
	U.struts(self, segs, 0.03, m_frame)

## Kazbek-style individually moulded seat liner on a shock-absorbing frame
func _seat(pos: Vector3, me: bool) -> void:
	var s := Node3D.new(); s.position = pos; add_child(s)
	# frame & shock struts
	for zz in [-0.24, 0.24]:
		U.beam(s, Vector3(0.55, 0.06, zz), Vector3(0.45, 0.32, zz), 0.022, m_alu)
		U.beam(s, Vector3(-0.35, 0.06, zz), Vector3(-0.2, 0.36, zz), 0.022, m_alu)
		U.cyl(s, 0.03, 0.03, 0.16, Vector3(0.5, 0.18, zz), m_dark, 12, Vector3(0, 0, 0.35))
	# moulded shell: back pan (torso), seat pan, raised thigh and lower-leg sections (knees bent up)
	var back := U.rbox(s, Vector3(0.78, 0.07, 0.5), 0.03, Vector3(0.34, 0.36, 0), m_seat, Vector3(0, 0, deg_to_rad(-12)))
	U.rbox(s, Vector3(0.7, 0.04, 0.42), 0.02, Vector3(0.34, 0.405, 0), m_cush, Vector3(0, 0, deg_to_rad(-12)))
	U.rbox(s, Vector3(0.22, 0.12, 0.3), 0.05, Vector3(0.76, 0.52, 0), m_cush, Vector3(0, 0, deg_to_rad(-12)))   # headrest
	for zz in [-0.27, 0.27]:
		U.rbox(s, Vector3(0.72, 0.16, 0.05), 0.02, Vector3(0.34, 0.45, zz), m_seat, Vector3(0, 0, deg_to_rad(-12)))  # side bolsters
	U.rbox(s, Vector3(0.42, 0.06, 0.46), 0.025, Vector3(-0.1, 0.42, 0), m_seat, Vector3(0, 0, deg_to_rad(38)))     # thighs (up)
	U.rbox(s, Vector3(0.42, 0.06, 0.4), 0.025, Vector3(-0.38, 0.5, 0), m_seat, Vector3(0, 0, deg_to_rad(-40)))     # lower legs
	U.rbox(s, Vector3(0.06, 0.18, 0.34), 0.02, Vector3(-0.56, 0.36, 0), m_seat)                                    # footrest
	# five-point harness straps
	var strap := U.mat(Color(0.18, 0.28, 0.5), 0.9)
	for zz in [-0.14, 0.14]:
		U.box(s, Vector3(0.5, 0.008, 0.045), Vector3(0.36, 0.53, zz), strap, Vector3(0, 0, deg_to_rad(-12)))
	U.cyl(s, 0.05, 0.05, 0.02, Vector3(0.18, 0.55, 0), m_alu, 16)
	if me:
		_hand_controllers(s)
	else:
		_crewmate(s, pos.z)

func _hand_controllers(s: Node3D) -> void:
	# left: translation controller (T-handle), right: rotation controller (pistol grip), on armrests near the hands
	for zz in [-0.34, 0.34]:
		U.rbox(s, Vector3(0.24, 0.05, 0.1), 0.02, Vector3(0.06, 0.47, zz), m_dark)
		var base := U.cyl(s, 0.035, 0.045, 0.05, Vector3(0.0, 0.52, zz), m_alu, 16)
		if zz < 0:
			U.beam(s, Vector3(0.0, 0.53, zz), Vector3(0.0, 0.62, zz), 0.012, m_dark)
			U.rbox(s, Vector3(0.03, 0.03, 0.12), 0.012, Vector3(0.0, 0.63, zz), m_dark)
		else:
			U.rbox(s, Vector3(0.045, 0.12, 0.04), 0.018, Vector3(0.0, 0.6, zz), m_dark, Vector3(0, 0, 0.3))
			U.box(s, Vector3(0.012, 0.012, 0.012), Vector3(0.012, 0.665, zz), U.emissive(Color(0.9, 0.1, 0.05), 2.0))

func _crewmate(s: Node3D, side: float) -> void:
	# suited crew member lying in the seat (Feitian-style intravehicular suit), visor down
	var c := Node3D.new(); s.add_child(c); crew.append(c)
	var tilt := Vector3(0, 0, deg_to_rad(-12))
	U.rbox(c, Vector3(0.62, 0.22, 0.4), 0.09, Vector3(0.36, 0.53, 0), m_suit, tilt)               # torso
	U.rbox(c, Vector3(0.14, 0.05, 0.3), 0.02, Vector3(0.42, 0.65, 0), U.mat(Color(0.75, 0.75, 0.72), 0.7), tilt)  # chest control unit
	U.box(c, Vector3(0.1, 0.006, 0.08), Vector3(0.5, 0.67, 0.07), U.mat(Color(0.8, 0.1, 0.08), 0.6), tilt)        # flag patch
	U.sphere(c, 0.16, Vector3(0.82, 0.64, 0), m_suit, 24)                                          # helmet shell
	var visor := U.sphere(c, 0.135, Vector3(0.79, 0.69, 0), U.mat(Color(0.25, 0.22, 0.12), 0.05, 1.0), 24)
	visor.scale = Vector3(0.9, 0.75, 0.95)
	U.cyl(c, 0.15, 0.15, 0.04, Vector3(0.68, 0.62, 0), U.mat(Color(0.2, 0.35, 0.7), 0.5, 0.4), 24, Vector3(0, 0, PI * 0.5 - 0.2))  # neck ring
	for zz in [-0.25, 0.25]:
		var arm := U.rbox(c, Vector3(0.36, 0.11, 0.11), 0.05, Vector3(0.32, 0.6, zz * 1.02), m_suit, Vector3(0, zz * 0.3, deg_to_rad(-30)))
		U.rbox(c, Vector3(0.1, 0.06, 0.09), 0.03, Vector3(0.13, 0.67, zz * 0.9), U.mat(Color(0.2, 0.32, 0.62), 0.7), Vector3(0, 0, -0.5))   # gloves
		U.rbox(c, Vector3(0.44, 0.14, 0.14), 0.06, Vector3(-0.08, 0.53, zz * 0.38), m_suit, Vector3(0, 0, deg_to_rad(38)))   # thighs
		U.rbox(c, Vector3(0.42, 0.12, 0.12), 0.05, Vector3(-0.36, 0.6, zz * 0.36), m_suit, Vector3(0, 0, deg_to_rad(-40)))   # shins
		U.rbox(c, Vector3(0.1, 0.16, 0.11), 0.04, Vector3(-0.54, 0.46, zz * 0.36), U.mat(Color(0.25, 0.24, 0.24), 0.8))   # boots
	# suit umbilical: ventilation + O2 hose and comm cable to the wall
	var hm := U.mat(Color(0.25, 0.45, 0.72), 0.6); hm.cull_mode = BaseMaterial3D.CULL_DISABLED
	U.hose(c, PackedVector3Array([Vector3(0.3, 0.6, 0.12), Vector3(0.25, 0.75, 0.25), Vector3(0.15, 0.8, 0.45 * signf(side)), Vector3(0.05, 0.75, 0.95 * signf(side))]), 0.022, hm)

## main panel: angled console above the crew's knees
func _main_panel() -> void:
	panel_root = Node3D.new(); add_child(panel_root)
	U.aim(panel_root, PANEL_POS, PANEL_POS + (EYE - PANEL_POS).normalized(), Vector3(1, 0, 0))
	panel_root.rotate_object_local(Vector3.UP, PI)   # +Z toward the crew
	var hous := U.mat(Color(0.2, 0.22, 0.24), 0.75, 0.1, 1.0)
	U.rbox(panel_root, Vector3(1.12, 0.72, 0.12), 0.03, Vector3(0, 0, -0.08), hous)
	U.rbox(panel_root, Vector3(1.14, 0.04, 0.16), 0.015, Vector3(0, 0.37, -0.02), m_frame)   # glare shield
	# three multifunction displays across the top
	screens = []
	for i in 3:
		var sc := MeshInstance3D.new(); var q := QuadMesh.new(); q.size = Vector2(0.3, 0.1875); sc.mesh = q; sc.position = Vector3((i - 1) * 0.35, 0.215, 0.004)
		add_screen_bezel(panel_root, sc.position, Vector2(0.3, 0.1875)); panel_root.add_child(sc); screens.append(sc)
	# support struts to the hull
	for x in [-0.5, 0.5]:
		var a := panel_root.to_global(Vector3(x, 0.25, -0.12)); var b := Vector3(a.x + 0.2, a.y + 0.35, a.z * 1.05)
		U.beam(self, to_local(a), to_local(b), 0.02, m_alu)
	# grab handles both ends
	for x in [-0.58, 0.58]:
		U.beam(panel_root, Vector3(x, -0.25, 0.0), Vector3(x, 0.25, 0.0), 0.012, m_alu)
		U.beam(panel_root, Vector3(x * 0.95, -0.25, -0.05), Vector3(x, -0.25, 0.0), 0.012, m_alu)
		U.beam(panel_root, Vector3(x * 0.95, 0.25, -0.05), Vector3(x, 0.25, 0.0), 0.012, m_alu)

func add_screen_bezel(parent: Node3D, pos: Vector3, sz: Vector2) -> void:
	U.rbox(parent, Vector3(sz.x + 0.05, sz.y + 0.05, 0.02), 0.006, pos + Vector3(0, 0, -0.008), U.mat(Color(0.08, 0.08, 0.09), 0.4, 0.3))
	for k in 6:   # soft keys along the bottom bezel
		U.rbox(parent, Vector3(0.04, 0.016, 0.01), 0.003, pos + Vector3(-sz.x * 0.42 + k * sz.x * 0.168, -sz.y * 0.5 - 0.014, 0.0), U.mat(Color(0.35, 0.36, 0.38), 0.5, 0.4))

## console surfaces for the switch panels: {node, x, y, w, h}
func surfaces() -> Array:
	return [{"node": panel_root, "x": -0.54, "y": 0.085, "w": 1.08, "h": 0.42},
		{"node": side_l, "x": -0.28, "y": 0.29, "w": 0.56, "h": 0.58},
		{"node": side_r, "x": -0.28, "y": 0.29, "w": 0.56, "h": 0.58}]

func _side_panels() -> void:
	# side consoles on the wall beside the outer seats, tilted toward the commander's eye
	side_l = Node3D.new(); side_r = Node3D.new()
	for k in 2:
		var sp: Node3D = [side_l, side_r][k]; var s := -1.0 if k == 0 else 1.0
		var p := Vector3(0.05, 0.95, s * 0.68)
		add_child(sp); U.aim(sp, p, EYE, Vector3(1, 0, 0)); sp.rotate_object_local(Vector3.UP, PI)
		U.rbox(sp, Vector3(0.58, 0.6, 0.06), 0.02, Vector3(0, 0, -0.05), U.mat(Color(0.2, 0.22, 0.24), 0.75, 0.1, 1.0))

func _windows() -> void:
	# two portholes beside the crew's heads + the optical viewer (periscope) window in the floor near the feet
	for s in [-1.0, 1.0]:
		var y := 1.0; var r := inner_r(y)
		var dir := Vector3(0.45, 0, s).normalized()
		var p := dir * (r - 0.005) + Vector3(0, y, 0)
		var w := Node3D.new(); add_child(w); U.aim(w, p, Vector3(0, y, 0), Vector3.UP)
		var ring := U.put(w, U.lathe(PackedVector2Array([Vector2(0.16, 0.0), Vector2(0.18, 0.02), Vector2(0.2, 0.05), Vector2(0.16, 0.05)]), 48), m_alu)
		ring.rotation.x = -PI * 0.5
		var gl := U.cyl(w, 0.155, 0.155, 0.01, Vector3(0, 0, 0.03), U.glass(), 48, Vector3(PI * 0.5, 0, 0))
		var cover := U.cyl(w, 0.17, 0.17, 0.012, Vector3(0, 0, -0.06), m_dark, 48, Vector3(PI * 0.5, 0, 0))   # outside: blocked by the fairing on the pad
		w.set_meta("cover", cover)

func _hatch() -> void:
	# overhead hatch to the orbital module with its hand wheel
	hatch = Node3D.new(); hatch.position = Vector3(0, H - 0.02, 0); add_child(hatch)
	U.cyl(hatch, 0.4, 0.42, 0.05, Vector3.ZERO, m_frame, 48)
	U.cyl(hatch, 0.34, 0.34, 0.03, Vector3(0, -0.035, 0), U.mat(Color(0.62, 0.63, 0.65), 0.4, 0.7, 1.0), 48)
	var wheel := Node3D.new(); wheel.position = Vector3(0, -0.09, 0); hatch.add_child(wheel)
	U.put(wheel, U.lathe(PackedVector2Array([Vector2(0.17, -0.008), Vector2(0.185, 0.0), Vector2(0.17, 0.008), Vector2(0.155, 0.0), Vector2(0.17, -0.008)]), 32), m_alu)
	for k in 3:
		var a := TAU * k / 3.0
		U.beam(wheel, Vector3.ZERO, Vector3(sin(a) * 0.17, 0, cos(a) * 0.17), 0.01, m_alu)
	U.cyl(wheel, 0.03, 0.03, 0.05, Vector3.ZERO, m_dark, 16)

func _details() -> void:
	# cable bundles along the walls, handrails, stowage bags, fan, fire extinguisher, labels
	var cable := U.mat(Color(0.22, 0.22, 0.2), 0.7); cable.cull_mode = BaseMaterial3D.CULL_DISABLED
	for k in 5:
		var a := -0.9 + k * 0.45
		var pts := PackedVector3Array()
		for j in 7:
			var y := 0.25 + j * 0.28
			var r := inner_r(y) - 0.03
			pts.append(Vector3(sin(a + PI) * r, y, cos(a + PI) * r))
		U.hose(self, pts, 0.018 + 0.006 * (k % 2), cable, 6)
	for k in 4:
		var a := PI * 0.5 + (k - 1.5) * 0.5
		var y := 1.55; var r := inner_r(y) - 0.06
		U.beam(self, Vector3(sin(a) * r, y - 0.12, cos(a) * r), Vector3(sin(a) * r, y + 0.12, cos(a) * r), 0.012, U.mat(Color(0.85, 0.55, 0.12), 0.4, 0.6))
	var bag := U.mat(Color(0.62, 0.62, 0.55), 0.95, 0.0, 2.0)
	for p in [Vector3(-0.85, 0.9, 0.35), Vector3(-0.8, 0.95, -0.38), Vector3(0.7, 1.35, 0.42)]:
		var b := U.rbox(self, Vector3(0.22, 0.28, 0.14), 0.05, p, bag)
		U.aim(b, p, Vector3(0, p.y, 0), Vector3.UP)
	U.cyl(self, 0.05, 0.05, 0.36, Vector3(0.75, 1.1, -0.58), U.mat(Color(0.75, 0.1, 0.08), 0.4, 0.3), 16, Vector3(0.4, 0, 0))
	var fan := U.cyl(self, 0.09, 0.09, 0.07, Vector3(0.62, 1.55, 0.0), m_dark, 24, Vector3(0, 0, PI * 0.45))
	# plush toy "zero-g indicator" hanging from the hatch
	var cord := U.beam(self, Vector3(0, H - 0.1, 0.12), Vector3(0, H - 0.42, 0.12), 0.002, U.mat(Color(0.1, 0.1, 0.1), 0.8))
	U.sphere(self, 0.045, Vector3(0, H - 0.46, 0.12), U.mat(Color(1.0, 0.6, 0.2), 0.95), 16)

func _lighting() -> void:
	for p in [Vector3(0.55, 1.55, -0.45), Vector3(0.55, 1.55, 0.45)]:
		var l := SpotLight3D.new(); l.position = p; l.light_energy = 2.2; l.spot_range = 3.0; l.spot_angle = 70; l.light_color = Color(1.0, 0.97, 0.92)
		l.shadow_enabled = true; add_child(l); U.aim(l, p, Vector3(0, 0.5, 0), Vector3(1, 0, 0)); lights.append(l)
		U.rbox(self, Vector3(0.16, 0.03, 0.08), 0.01, p, U.emissive(Color(1, 0.98, 0.94), 3.0))
	var fill := OmniLight3D.new(); fill.position = Vector3(0, 1.2, 0); fill.light_energy = 0.35; fill.omni_range = 2.6; fill.light_color = Color(0.9, 0.95, 1.0)
	add_child(fill); lights.append(fill)
	var probe := ReflectionProbe.new(); probe.size = Vector3(2.4, 2.3, 2.4); probe.position = Vector3(0, 1.1, 0); probe.interior = true; probe.update_mode = ReflectionProbe.UPDATE_ONCE
	add_child(probe)

## debug: report console panels whose corners poke through the hull lining
func check_fit(console) -> int:
	var bad := 0
	for P in console.panels:
		var g: Node3D = P.node
		for c in [Vector3(-P.W * 0.5, -P.H * 0.5, 0.03), Vector3(P.W * 0.5, -P.H * 0.5, 0.03), Vector3(-P.W * 0.5, P.H * 0.5, 0.03), Vector3(P.W * 0.5, P.H * 0.5, 0.03)]:
			var q := to_local(g.to_global(c))
			var r := Vector2(q.x, q.z).length()
			if r > inner_r(q.y) - 0.015: bad += 1; print("[fit] panel ", P.spec.k, " corner r=%.2f lim=%.2f y=%.2f" % [r, inner_r(q.y), q.y])
	return bad

## Launch complex: concrete apron, flame trench, mobile launch platform on rails, umbilical/service tower with
## swing platforms, crew access arm + white room, elevator, lightning masts, flood lights, water tower, rail line.
class_name Pad
extends Node3D

const DECK := 8.0          # top of the mobile launch platform (rocket sits here)
const TOWER_X := -13.5     # tower centre
const TOWER_W := 10.0
const TOWER_H := 86.0
var arm_y := 0.0
var elevator: Node3D
var arm: Node3D
var white_room: Node3D
var floor_bodies: Node3D
var lights: Array[Light3D] = []

var concrete: StandardMaterial3D
var steel: StandardMaterial3D
var red: StandardMaterial3D
var grating: StandardMaterial3D

func _ready() -> void:
	concrete = U.tri_mat(Color(0.64, 0.63, 0.6), 0.88, 0.0, 1.2, 1.2)
	steel = U.mat(Color(0.82, 0.83, 0.85), 0.42, 0.65, 1.2)
	red = U.mat(Color(0.66, 0.11, 0.08), 0.5, 0.35, 1.0)
	grating = U.mat(Color(0.35, 0.36, 0.37), 0.6, 0.7, 2.0)
	floor_bodies = Node3D.new(); add_child(floor_bodies)
	arm_y = DECK + Rocket.Y_CAPSULE - 0.05
	_apron()
	_trench()
	_platform()
	_tower()
	_arm()
	_masts()
	_site_props()

func _col_box(size: Vector3, pos: Vector3, rot := Vector3.ZERO) -> void:
	var b := StaticBody3D.new(); var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = size
	cs.shape = bs; b.position = pos; b.rotation = rot; b.add_child(cs); floor_bodies.add_child(b)

func _apron() -> void:
	# poured slabs with expansion joints
	var slab := U.box(self, Vector3(260, 0.6, 220), Vector3(0, -0.3, 0), concrete)
	var joint := U.mat(Color(0.25, 0.24, 0.23), 0.9)
	var segs := []
	for i in range(-12, 13):
		segs.append([Vector3(i * 10.0, 0.005, -110), Vector3(i * 10.0, 0.005, 110)])
	for j in range(-11, 12):
		segs.append([Vector3(-130, 0.005, j * 10.0), Vector3(130, 0.005, j * 10.0)])
	var mm := U.struts(self, segs, 0.06, joint); mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for s in mm.multimesh.instance_count:
		var t := mm.multimesh.get_instance_transform(s); t.basis = t.basis.scaled(Vector3(1, 1, 0.08)); mm.multimesh.set_instance_transform(s, t)
	# painted safety lines and a road to the assembly building
	var yel := U.mat(Color(0.86, 0.66, 0.12), 0.7)
	U.box(self, Vector3(0.25, 0.02, 60), Vector3(22, 0.01, 0), yel); U.box(self, Vector3(0.25, 0.02, 60), Vector3(-34, 0.01, 0), yel)
	U.box(self, Vector3(12, 0.08, 1400), Vector3(60, 0.0, 800), U.tri_mat(Color(0.18, 0.18, 0.19), 0.85, 0.0, 0.5, 1.0))

func _trench() -> void:
	# flame trench running east, with a sloped deflector under the rocket
	var w := 10.0; var depth := 9.0; var L := 70.0
	var dark := U.tri_mat(Color(0.33, 0.31, 0.29), 0.95, 0.0, 0.4, 4.0)
	U.box(self, Vector3(L, 0.4, w), Vector3(L * 0.5 - 6, -depth, 0), dark)
	for s in [-1, 1]:
		U.box(self, Vector3(L, depth, 0.8), Vector3(L * 0.5 - 6, -depth * 0.5, s * (w * 0.5 + 0.4)), dark)
	var defl := U.box(self, Vector3(14, 0.6, w), Vector3(0, -depth * 0.55, 0), U.tri_mat(Color(0.24, 0.22, 0.2), 0.9, 0.2, 0.4, 5.0), Vector3(0, 0, deg_to_rad(-34)))
	# cover the apron slab where the trench opening is
	var hole := U.box(self, Vector3(L - 4, 0.02, w), Vector3(L * 0.5 - 4, 0.02, 0), U.mat(Color(0.03, 0.03, 0.03), 1.0))
	# water deluge pipes along the trench lips
	var pipe := U.mat(Color(0.55, 0.58, 0.6), 0.4, 0.8)
	for s in [-1, 1]:
		U.cyl(self, 0.35, 0.35, L, Vector3(L * 0.5 - 6, 0.5, s * (w * 0.5 + 1.4)), pipe, 16, Vector3(0, 0, PI * 0.5))

func _platform() -> void:
	# mobile launch platform: box girder deck on two rail bogies, with the flame hole and four hold-down posts
	var pl := Node3D.new(); pl.name = "MLP"; add_child(pl)
	var deck_m := U.mat(Color(0.52, 0.53, 0.55), 0.55, 0.6, 1.5)
	var H := 4.2; var S := 22.0; var y := DECK - H * 0.5
	for s in [-1, 1]:
		U.box(pl, Vector3(S, H, 6.5), Vector3(0, y, s * 7.75), deck_m)
		U.box(pl, Vector3(6.5, H, S - 13.0), Vector3(s * 7.75, y, 0), deck_m)
	# girder ribs on the sides
	var ribs := []
	for i in 12:
		var x := -S * 0.5 + i * S / 11.0
		ribs.append([Vector3(x, DECK - H, S * 0.5 + 0.02), Vector3(x, DECK, S * 0.5 + 0.02)])
		ribs.append([Vector3(x, DECK - H, -S * 0.5 - 0.02), Vector3(x, DECK, -S * 0.5 - 0.02)])
	U.struts(pl, ribs, 0.25, steel)
	# support legs down to the ground and rail bogies
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			U.box(pl, Vector3(2.4, DECK - H, 2.4), Vector3(sx * 9.0, (DECK - H) * 0.5, sz * 9.0), deck_m)
			U.box(pl, Vector3(4.0, 1.0, 2.0), Vector3(sx * 9.0, 0.5, sz * 9.0), U.mat(Color(0.2, 0.2, 0.22), 0.6, 0.6))
	for sz in [-1, 1]:
		U.box(self, Vector3(0.18, 0.2, 1600), Vector3(-9.0 + sz * 0.0, 0.1, 760), steel).position.x = 9.0 * sz
	# hold-down arms gripping the core skirt + booster bases
	var hd := U.mat(Color(0.25, 0.26, 0.28), 0.5, 0.75)
	for i in 4:
		var a := TAU * i / 4.0 + PI / 4.0; var d := Vector3(sin(a), 0, cos(a))
		var p := d * (Rocket.R_CORE + Rocket.R_BST + 0.08)
		U.box(pl, Vector3(0.6, 1.6, 0.6), p + Vector3(0, DECK + 0.8, 0) + d * 1.4, hd)
		U.beam(pl, p + d * 1.4 + Vector3(0, DECK + 1.5, 0), p + d * 0.9 + Vector3(0, DECK + 0.2, 0), 0.12, hd)
	# umbilical masts at the deck (tail service masts)
	for s in [-1, 1]:
		var m := U.box(pl, Vector3(1.0, 4.0, 1.6), Vector3(-6.5, DECK + 2.0, s * 3.5), red)
	_col_box(Vector3(S, 1, S), Vector3(0, DECK - 0.5, 0))

func _lattice_column(parent: Node, x: float, z: float, h: float, segs: Array) -> void:
	segs.append([Vector3(x, 0, z), Vector3(x, h, z)])

func _tower() -> void:
	var t := Node3D.new(); t.name = "Tower"; t.position = Vector3(TOWER_X, 0, 0); add_child(t)
	var hw := TOWER_W * 0.5
	var cols := []; var braces := []; var floors := []
	for cx in [-hw, hw]:
		for cz in [-hw, hw]:
			cols.append([Vector3(cx, 0, cz), Vector3(cx, TOWER_H, cz)])
	var lvl := 4.2; var n := int(TOWER_H / lvl)
	for i in n:
		var y0 := i * lvl; var y1 := y0 + lvl
		for side in 4:
			var a := Vector3(-hw, 0, -hw); var b := Vector3(hw, 0, -hw)
			match side:
				1: a = Vector3(hw, 0, -hw); b = Vector3(hw, 0, hw)
				2: a = Vector3(hw, 0, hw); b = Vector3(-hw, 0, hw)
				3: a = Vector3(-hw, 0, hw); b = Vector3(-hw, 0, -hw)
			braces.append([a + Vector3(0, y0, 0), b + Vector3(0, y1, 0)])
			braces.append([b + Vector3(0, y0, 0), a + Vector3(0, y1, 0)])
			floors.append([a + Vector3(0, y1, 0), b + Vector3(0, y1, 0)])
			# intermediate verticals
			floors.append([a.lerp(b, 0.5) + Vector3(0, y0, 0), a.lerp(b, 0.5) + Vector3(0, y1, 0)])
	U.struts(t, cols, 0.55, red)
	U.struts(t, braces, 0.16, red)
	U.struts(t, floors, 0.22, red)
	# work platforms every other level, grated, with handrails
	var rails := []
	for i in range(1, n):
		if i % 2 == 1: continue
		var y := i * lvl
		U.box(t, Vector3(TOWER_W - 0.2, 0.12, TOWER_W - 0.2), Vector3(0, y, 0), grating)
		# outrigger platform facing the rocket
		U.box(t, Vector3(2.2, 0.12, 6.0), Vector3(hw + 1.1, y, 0), grating)
		for k in 7:
			var z := -3.0 + k
			rails.append([Vector3(hw + 2.2, y, z), Vector3(hw + 2.2, y + 1.1, z)])
		rails.append([Vector3(hw + 2.2, y + 1.1, -3), Vector3(hw + 2.2, y + 1.1, 3)])
		rails.append([Vector3(hw + 2.2, y + 0.55, -3), Vector3(hw + 2.2, y + 0.55, 3)])
	U.struts(t, rails, 0.05, U.mat(Color(0.9, 0.75, 0.1), 0.5, 0.3), false)
	# enclosed elevator shaft on the west face + stairs
	var shaft := U.mat(Color(0.86, 0.86, 0.84), 0.6, 0.2, 1.0)
	U.box(t, Vector3(3.0, TOWER_H, 0.08), Vector3(-hw - 1.6, TOWER_H * 0.5, -1.5), shaft)
	U.box(t, Vector3(3.0, TOWER_H, 0.08), Vector3(-hw - 1.6, TOWER_H * 0.5, 1.5), shaft)
	U.box(t, Vector3(0.08, TOWER_H, 3.0), Vector3(-hw - 3.1, TOWER_H * 0.5, 0), shaft)
	elevator = Node3D.new(); elevator.position = Vector3(-hw - 1.6, 0.1, 0); t.add_child(elevator)
	U.box(elevator, Vector3(2.6, 0.15, 2.6), Vector3.ZERO, grating)
	U.box(elevator, Vector3(2.6, 0.15, 2.6), Vector3(0, 2.6, 0), shaft)
	# cable trays and propellant lines running up the tower to the rocket
	var pipe := U.mat(Color(0.7, 0.72, 0.74), 0.35, 0.85)
	for k in 3:
		U.cyl(t, 0.18, 0.18, TOWER_H - 6, Vector3(hw + 0.4, (TOWER_H - 6) * 0.5, -1.2 + k * 1.2), pipe, 12)
	# swing service platforms (rotated open for launch) at stage-2 and fairing levels
	for y in [DECK + 30.0, DECK + 40.0, DECK + 52.0]:
		var sp := Node3D.new(); sp.position = Vector3(hw, y, -hw); sp.rotation.y = deg_to_rad(-80); t.add_child(sp)
		U.box(sp, Vector3(9.0, 0.3, 2.4), Vector3(4.5, 0, 1.2), grating)
		U.struts(sp, [[Vector3(0, 0, 0), Vector3(9, 0, 0)], [Vector3(0, 0, 2.4), Vector3(9, 0, 2.4)], [Vector3(0, -1.6, 0), Vector3(9, 0, 0)]], 0.18, red)
	# top: lightning rod, aircraft warning lights, crane
	U.box(t, Vector3(TOWER_W + 1, 1.2, TOWER_W + 1), Vector3(0, TOWER_H + 0.6, 0), red)
	U.beam(t, Vector3(0, TOWER_H + 1.2, 0), Vector3(0, TOWER_H + 14, 0), 0.12, steel)
	U.beam(t, Vector3(0, TOWER_H + 3, 0), Vector3(TOWER_W * 0.5 + 9, TOWER_H + 3.5, 0), 0.25, U.mat(Color(0.9, 0.7, 0.1), 0.5, 0.4))
	for p in [Vector3(hw, TOWER_H + 1.3, hw), Vector3(-hw, TOWER_H + 1.3, -hw)]:
		U.sphere(t, 0.25, p, U.emissive(Color(1.0, 0.1, 0.05), 6.0), 8)
	_col_box(Vector3(TOWER_W + 6, 0.3, TOWER_W), Vector3(TOWER_X, arm_y - 0.15, 0))

func _arm() -> void:
	# crew access arm from the tower to the fairing hatch, ending in the white room
	arm = Node3D.new(); arm.name = "CrewArm"; arm.position = Vector3(TOWER_X + TOWER_W * 0.5, arm_y, 0); add_child(arm)
	var L := -TOWER_X - TOWER_W * 0.5 - Rocket.R_FAIR - 2.6
	var wall := U.mat(Color(0.88, 0.88, 0.86), 0.55, 0.15, 1.0)
	U.box(arm, Vector3(L, 0.2, 1.8), Vector3(L * 0.5, 0, 0), grating)
	for s in [-1, 1]:
		U.box(arm, Vector3(L, 2.4, 0.06), Vector3(L * 0.5, 1.2, s * 0.9), wall)
		U.struts(arm, [[Vector3(0, -0.8, s * 0.9), Vector3(L, -0.8, s * 0.9)], [Vector3(0, -0.8, s * 0.9), Vector3(L * 0.5, 0, s * 0.9)], [Vector3(L * 0.5, 0, s * 0.9), Vector3(L, -0.8, s * 0.9)]], 0.16, red)
	U.box(arm, Vector3(L, 0.08, 1.9), Vector3(L * 0.5, 2.44, 0), wall)
	# white room hugging the fairing
	white_room = Node3D.new(); white_room.position = Vector3(L, 0, 0); arm.add_child(white_room)
	var W := 2.6
	U.box(white_room, Vector3(W, 0.2, 3.2), Vector3(W * 0.5, 0, 0), U.mat(Color(0.75, 0.76, 0.78), 0.5, 0.2, 1.0))
	for s in [-1, 1]:
		U.box(white_room, Vector3(W, 2.7, 0.08), Vector3(W * 0.5, 1.35, s * 1.6), wall)
	U.box(white_room, Vector3(W, 0.08, 3.3), Vector3(W * 0.5, 2.72, 0), wall)
	var lamp := OmniLight3D.new(); lamp.position = Vector3(W * 0.5, 2.4, 0); lamp.light_energy = 1.4; lamp.omni_range = 5.0; lamp.light_color = Color(0.95, 0.97, 1.0)
	white_room.add_child(lamp); lights.append(lamp)
	U.box(white_room, Vector3(0.8, 0.04, 0.2), Vector3(W * 0.5, 2.68, 0), U.emissive(Color(1, 1, 1), 3.0))
	var arm_col_len := L + W
	_col_box(Vector3(arm_col_len, 0.2, 1.8), Vector3(TOWER_X + TOWER_W * 0.5 + arm_col_len * 0.5, arm_y - 0.1, 0))

func _masts() -> void:
	# four lightning protection masts with catenary wires, plus flood-light towers
	var mast := U.mat(Color(0.7, 0.72, 0.74), 0.5, 0.6, 1.0)
	var pts := [Vector3(-60, 0, -60), Vector3(60, 0, -60), Vector3(60, 0, 60), Vector3(-60, 0, 60)]
	var tops := []
	for p: Vector3 in pts:
		var segs := []
		var h := 118.0
		for i in 3:
			var a := TAU * i / 3.0
			segs.append([p + Vector3(sin(a) * 2.5, 0, cos(a) * 2.5), p + Vector3(sin(a) * 0.6, h, cos(a) * 0.6)])
		for k in 24:
			var y := k * h / 24.0; var r := lerpf(2.5, 0.6, y / h)
			for i in 3:
				var a0 := TAU * i / 3.0; var a1 := TAU * (i + 1) / 3.0
				segs.append([p + Vector3(sin(a0) * r, y, cos(a0) * r), p + Vector3(sin(a1) * r, y + h / 24.0, cos(a1) * r)])
		U.struts(self, segs, 0.14, mast, false)
		tops.append(p + Vector3(0, h, 0))
		U.sphere(self, 0.3, p + Vector3(0, h + 0.3, 0), U.emissive(Color(1, 0.12, 0.05), 5.0), 8)
	var wire := []
	for i in 4:
		var a: Vector3 = tops[i]; var b: Vector3 = tops[(i + 1) % 4]
		for k in 16:
			var t0 := k / 16.0; var t1 := (k + 1) / 16.0
			wire.append([a.lerp(b, t0) - Vector3(0, 8.0 * sin(PI * t0), 0), a.lerp(b, t1) - Vector3(0, 8.0 * sin(PI * t1), 0)])
	U.struts(self, wire, 0.04, U.mat(Color(0.2, 0.2, 0.2), 0.5, 0.8), false)
	# flood lights for night ops
	for p in [Vector3(40, 0, -45), Vector3(-45, 0, 40), Vector3(45, 0, 45)]:
		U.cyl(self, 0.35, 0.5, 30, p + Vector3(0, 15, 0), mast, 12)
		var head := U.box(self, Vector3(4, 1.6, 0.6), p + Vector3(0, 30.6, 0), U.mat(Color(0.3, 0.3, 0.32), 0.5, 0.6))
		head.look_at_from_position(head.position, Vector3(0, 40, 0))

func _site_props() -> void:
	# water tower, propellant storage tanks, equipment shelters, fences
	var white := U.mat(Color(0.88, 0.88, 0.86), 0.55, 0.2, 1.0)
	U.cyl(self, 6.0, 6.0, 12.0, Vector3(-85, 34, 70), white, 48)
	U.cyl(self, 0.8, 0.8, 28.0, Vector3(-85, 14, 70), U.mat(Color(0.7, 0.7, 0.72), 0.5, 0.6), 16)
	for k in 4:
		var p := Vector3(80, 2.2, -70 + k * 9)
		U.cyl(self, 2.0, 2.0, 16, p, white, 32, Vector3(0, 0, PI * 0.5))
		for s in [-6, 6]: U.box(self, Vector3(0.6, 1.4, 3.2), p + Vector3(s, -1.5, 0), concrete)
	for k in 5:
		var b := U.box(self, Vector3(12, 4, 8), Vector3(-95 + k * 16, 2, -95), U.mat(Color(0.8, 0.79, 0.74), 0.7, 0.1, 1.0))
		U.box(self, Vector3(12.4, 0.3, 8.4), Vector3(-95 + k * 16, 4.15, -95), U.mat(Color(0.3, 0.45, 0.6), 0.6, 0.3))
	var fence := []
	for i in 64:
		var a := TAU * i / 64.0
		fence.append([Vector3(sin(a) * 125, 0, cos(a) * 105), Vector3(sin(a) * 125, 2.4, cos(a) * 105)])
	U.struts(self, fence, 0.08, U.mat(Color(0.6, 0.62, 0.64), 0.5, 0.6), false)
	# distant vertical assembly building at the end of the rail line
	var vab := Node3D.new(); vab.position = Vector3(30, 0, 1500); add_child(vab)
	U.box(vab, Vector3(60, 95, 45), Vector3(0, 47.5, 0), U.tri_mat(Color(0.86, 0.85, 0.82), 0.7, 0.1, 0.1, 1.5))
	U.box(vab, Vector3(24, 85, 0.4), Vector3(0, 42.5, -22.6), U.mat(Color(0.45, 0.5, 0.55), 0.5, 0.5))
	U.label(vab, "垂直总装测试厂房", Vector3(0, 88, -22.9), 4.0, Color(0.7, 0.1, 0.08), Vector3(0, PI, 0))

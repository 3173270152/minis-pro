## Spectator mode: grandstand ~1.4 km from the pad with a crowd, PA announcer, telescope zoom, auto-tracking,
## sound arriving late (speed of sound) and fading with distance.
extends Node3D

const STAND := Vector3(-700, 0, 1230)
var g
var active := false
var stand: Node3D
var big: Label3D
var said := {}
var thr_hist: Array = []     # [time, throttle] for the delayed sound

func setup(game) -> void:
	g = game
	if g.cfg.mode != "spectator": return
	active = true
	stand = Node3D.new(); stand.position = STAND; g.site.add_child(stand)
	_build_stand()
	g.cam_mode = "module"; g.yaw = 0.0; g.pitch = 0.05
	g.hud.objective.text = "观众模式：拖动环视 · 双指/滚轮望远镜（最高 16 倍）· 「外部视角」切换自动跟踪火箭"
	g.sfx.line("pawelcome", 1.5)

func _build_stand() -> void:
	var conc := U.tri_mat(Color(0.7, 0.69, 0.66), 0.85, 0.0, 0.6, 1.0)
	var seat := U.mat(Color(0.15, 0.32, 0.62), 0.6, 0.1)
	var face := (Vector3.ZERO - STAND).normalized(); var yaw0 := atan2(face.x, face.z)
	stand.rotation.y = yaw0
	for i in 8:   # stepped tiers
		U.box(stand, Vector3(60, 0.45 * (i + 1), 1.2), Vector3(0, 0.225 * (i + 1), -i * 1.2), conc)
		U.box(stand, Vector3(58, 0.12, 0.45), Vector3(0, 0.45 * (i + 1) + 0.06, -i * 1.2 + 0.2), seat)
	# canopy on columns
	var steel := U.mat(Color(0.82, 0.83, 0.85), 0.4, 0.6)
	for x in range(-28, 29, 8):
		U.cyl(stand, 0.18, 0.18, 9.0, Vector3(x, 4.5, -10.0), steel, 10)
	var roof := U.box(stand, Vector3(62, 0.25, 12), Vector3(0, 9.0, -5.0), U.mat(Color(0.92, 0.92, 0.9), 0.5, 0.2), Vector3(deg_to_rad(-6), 0, 0))
	# crowd: instanced figures with random shirt colours
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_colors = true
	var cap := CapsuleMesh.new(); cap.radius = 0.22; cap.height = 1.65; cap.radial_segments = 8; cap.rings = 2; mm.mesh = cap
	var n := 0; var pts := []
	for i in 8:
		for x in range(-28, 29):
			if randf() < 0.62: pts.append(Vector3(x + randf_range(-0.3, 0.3), 0.45 * (i + 1) + 0.8, -i * 1.2 + randf_range(-0.1, 0.2)))
	mm.instance_count = pts.size()
	for p in pts:
		mm.set_instance_transform(n, Transform3D(Basis(), p))
		mm.set_instance_color(n, Color.from_hsv(randf(), randf_range(0.3, 0.8), randf_range(0.5, 0.95))); n += 1
	var mmi := MultiMeshInstance3D.new(); mmi.multimesh = mm
	var cm := StandardMaterial3D.new(); cm.vertex_color_use_as_albedo = true; cm.roughness = 0.8; mmi.material_override = cm
	stand.add_child(mmi)
	# flags and a big countdown screen
	for x in [-30.0, 30.0]:
		U.cyl(stand, 0.06, 0.06, 12.0, Vector3(x, 6.0, 2.0), steel, 8)
		U.box(stand, Vector3(1.8, 1.2, 0.02), Vector3(x + 0.9, 11.2, 2.0), U.mat(Color(0.85, 0.1, 0.07), 0.8))
	U.box(stand, Vector3(10, 5.6, 0.3), Vector3(0, 13.0, -12.0), U.mat(Color(0.05, 0.05, 0.06), 0.4, 0.5))
	big = U.label(stand, "T−01:40", Vector3(0, 13.0, -11.8), 2.6, Color(1.0, 0.6, 0.2))
	big.rotation.y = PI

func tick(dt: float) -> void:
	if not active: return
	g.cam_mode = "module"
	var eye: Vector3 = g.site.global_position + STAND + Vector3(0, 5.6, -4.0).rotated(Vector3.UP, stand.rotation.y)
	var cam: Camera3D = g.cam
	cam.global_position = eye
	var tgt: Vector3 = g.rocket.global_position + g.rocket.global_transform.basis.y * 30.0
	var fov: float = 60.0 / (g.zoom * g.zoom)
	if g.spec_track:
		cam.look_at(tgt, Vector3.UP)
		cam.rotate_object_local(Vector3.UP, g.yaw * 0.15); cam.rotate_object_local(Vector3.RIGHT, g.pitch * 0.15)
	else:
		var base := Basis.looking_at(Vector3(0, 30, 0) + g.site.global_position - eye, Vector3.UP)
		cam.global_transform = Transform3D(base * Basis(Vector3.UP, g.yaw) * Basis(Vector3.RIGHT, g.pitch), eye)
	cam.fov = lerpf(cam.fov, fov, minf(1.0, dt * 6.0))
	big.text = Hud.fmt_t(g.T)
	# sound: delayed by distance / 343 m/s, attenuated
	var d: float = eye.distance_to(g.rocket.global_position)
	thr_hist.append([g.T, g.throttle])
	var lag: float = d / 343.0; var heard: float = 0.0
	while thr_hist.size() > 2 and thr_hist[1][0] < g.T - lag: thr_hist.pop_front()
	if thr_hist[0][0] <= g.T - lag: heard = thr_hist[0][1]
	g.sfx.set_engine(heard * clampf(2500.0 / maxf(d, 300.0), 0.05, 1.0), false, 0.0)
	# announcer
	var pa := {-60.0: "paterm", -45.0: "paarm", -20.0: "pago", -16.0: "padeluge", 2.0: "palift", 75.0: "pamaxq", 140.0: "pabsep", 158.0: "pameco", 584.0: "paseco"}
	for k in pa:
		if g.T >= k and not said.has(k): said[k] = true; g.sfx.line(pa[k])
	for n in range(10, 0, -1):
		if g.T >= -n and not said.has(-n - 0.5): said[-n - 0.5] = true; g.sfx.line("n%d" % n, 0.0, true)

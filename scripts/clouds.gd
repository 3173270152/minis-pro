## Physical cumulus field over the launch site: puff clusters the rocket climbs through (whiteout fog inside,
## flame glow lighting the cloud from within), on the curved Earth so it matches the terrain.
extends RefCounted

var g
var mmi: MultiMeshInstance3D
var mat: ShaderMaterial
var centres: Array = []   # [Vector3 site-frame centre, radius]

func setup(game) -> void:
	g = game
	var mobile: bool = OS.has_feature("mobile") or g.cfg.get("q", "") == "fast"
	var rng := RandomNumberGenerator.new(); rng.seed = 4242
	var nclu := 26 if mobile else 44; var per := 12 if mobile else 18
	# one cluster right on the ascent path so the climb passes through it
	centres.append([Vector3(150, 3300, 0), 650.0])
	for i in nclu - 1:
		var a := rng.randf() * TAU; var r := 2500.0 + rng.randf() * 32000.0
		centres.append([Vector3(cos(a) * r, 2600.0 + rng.randf() * 2600.0, sin(a) * r), 500.0 + rng.randf() * 900.0])
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_custom_data = true
	mm.mesh = QuadMesh.new(); mm.instance_count = centres.size() * per
	var k := 0
	for c in centres:
		var ctr: Vector3 = c[0]; var R: float = c[1]
		ctr.y -= (ctr.x * ctr.x + ctr.z * ctr.z) / (2.0 * 6371000.0)
		for j in per:
			var off := Vector3(rng.randf_range(-1, 1) * R, rng.randf_range(-0.25, 0.55) * R, rng.randf_range(-1, 1) * R)
			off.y *= 1.0 - Vector2(off.x, off.z).length() / (R * 1.6)   # domed top, flat base
			var s := R * rng.randf_range(0.55, 1.0)
			mm.set_instance_transform(k, Transform3D(Basis().scaled(Vector3(s, s, s)), ctr + off))
			mm.set_instance_custom_data(k, Color(rng.randf(), 0, 0, 0)); k += 1
	mmi = MultiMeshInstance3D.new(); mmi.multimesh = mm; mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.extra_cull_margin = 60000.0
	mat = ShaderMaterial.new(); mat.shader = load("res://shaders/cloudpuff.gdshader")
	mat.set_shader_parameter("puff", U.puff_tex()); mat.set_shader_parameter("nz", U.noise_tex(0.02, false, 77, 256, 4))
	mmi.material_override = mat
	g.site.add_child(mmi)

func tick(_dt: float) -> void:
	mmi.visible = g.world.terrain.visible
	if not mmi.visible: g.set_meta("cloud_fog", 0.0); return
	var sun: DirectionalLight3D = g.world.sun
	var sd: Vector3 = sun.global_transform.basis.z
	mat.set_shader_parameter("sun_dir", sd); mat.set_shader_parameter("day", clampf(sd.y * 3.0 + 0.3, 0.0, 1.0))
	var rp: Vector3 = g.rocket.global_position - g.rocket.global_transform.basis.y * 25.0
	mat.set_shader_parameter("flame_pos", rp); mat.set_shader_parameter("flame_pow", float(g.throttle) if g.lifted else 0.0)
	# whiteout when the camera is inside a cluster
	var cam: Vector3 = g.site.to_local(g.cam.global_position)
	var inside := 0.0
	for c in centres:
		var ctr: Vector3 = c[0]; var R: float = c[1]
		var d := (cam - ctr) / Vector3(R, R * 0.6, R)
		inside = maxf(inside, 1.0 - smoothstep(0.6, 1.0, d.length()))
	g.set_meta("cloud_fog", inside * 0.006)

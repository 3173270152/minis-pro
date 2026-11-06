## Launch visual effects: per-engine layered plumes that burn only when that stage fires, plume light,
## flame-trench steam/smoke clouds, water deluge, exhaust trail, vapour cone near Mach 1.
extends Node

var g
var plumes: Array = []      # [point, core MeshInstance, outer MeshInstance, group]
var light: OmniLight3D
var smoke: GPUParticles3D
var steam: GPUParticles3D
var deluge: GPUParticles3D
var tr_mm: MultiMesh
var tr_n := 0
var tr_i := 0
var tr_age: Array = []
var tr_pos: Array = []
var vapour: MeshInstance3D
var sep_t := -1.0
var _last_stage := 0
var _trail_acc := 0.0
var mobile := false

func setup(game) -> void:
	g = game
	mobile = OS.has_feature("mobile") or g.cfg.get("q", "") == "fast"
	var sh := load("res://shaders/plume.gdshader")
	var col := _colors(g.rocket.kind)
	for p in g.rocket.plume_points:
		var grp := "core"
		if g.rocket.stage2.is_ancestor_of(p): grp = "s2"
		for b in g.rocket.boosters: if b.is_ancestor_of(p): grp = "bst"
		var core := _cone(p, sh, 0.0, col); var outer := _cone(p, sh, 1.0, col)
		plumes.append([p, core, outer, grp])
	light = OmniLight3D.new(); light.light_color = Color(1.0, 0.6, 0.3); light.omni_range = 120.0; light.shadow_enabled = false; light.light_energy = 0.0
	g.rocket.add_child(light); light.position = Vector3(0, -8, 0)
	smoke = _puffs(g.site, 360 if mobile else 900, 20.0, Color(0.86, 0.85, 0.82, 0.6), 7.0, 22.0)
	smoke.position = Vector3(40, 3, 0)
	var pm: ParticleProcessMaterial = smoke.process_material
	pm.direction = Vector3(1, 0.25, 0); pm.spread = 55.0; pm.initial_velocity_min = 25.0; pm.initial_velocity_max = 70.0; pm.damping_min = 4.0; pm.damping_max = 8.0; pm.gravity = Vector3(1.2, 1.5, 0.6)
	steam = _puffs(g.site, 200 if mobile else 500, 16.0, Color(0.95, 0.95, 0.95, 0.5), 5.0, 16.0)
	steam.position = Vector3(0, Pad.DECK - 2.0, 0)
	(steam.process_material as ParticleProcessMaterial).spread = 180.0
	deluge = _puffs(g.site, 160 if mobile else 400, 2.5, Color(0.85, 0.9, 1.0, 0.35), 0.6, 2.0)
	deluge.position = Vector3(0, Pad.DECK + 1.0, 0)
	var dm: ParticleProcessMaterial = deluge.process_material
	dm.direction = Vector3(0, 1, 0); dm.spread = 35.0; dm.initial_velocity_min = 10.0; dm.initial_velocity_max = 18.0; dm.gravity = Vector3(0, -9.8, 0)
	tr_n = 260 if mobile else 600
	var q := QuadMesh.new(); var sm := StandardMaterial3D.new(); sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED; sm.billboard_keep_scale = true
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; sm.albedo_texture = _puff_tex(); sm.vertex_color_use_as_albedo = true; sm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	q.material = sm
	tr_mm = MultiMesh.new(); tr_mm.transform_format = MultiMesh.TRANSFORM_3D; tr_mm.use_colors = true; tr_mm.mesh = q; tr_mm.instance_count = tr_n
	for i in tr_n: tr_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)); tr_age.append(999.0); tr_pos.append(Vector3.ZERO)
	var tmi := MultiMeshInstance3D.new(); tmi.multimesh = tr_mm; tmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tmi.custom_aabb = AABB(Vector3(-5000, -100, -5000), Vector3(200000, 80000, 10000)); g.site.add_child(tmi)
	vapour = MeshInstance3D.new(); var cm := CylinderMesh.new(); cm.top_radius = 2.2; cm.bottom_radius = 5.5; cm.height = 9.0; cm.cap_top = false; cm.cap_bottom = false; vapour.mesh = cm
	var vm := StandardMaterial3D.new(); vm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; vm.albedo_color = Color(1, 1, 1, 0.0); vm.albedo_texture = U.noise_tex(0.05, false, 77, 256, 3)
	vm.cull_mode = BaseMaterial3D.CULL_DISABLED; vm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX; vapour.material_override = vm; vapour.visible = false
	g.rocket.add_child(vapour); vapour.position = Vector3(0, 42, 0)

func _colors(kind: String) -> Dictionary:
	match kind:
		"saturn": return {"hot": Color(1, 0.92, 0.7), "mid": Color(1, 0.6, 0.18), "tail": Color(0.35, 0.18, 0.08), "len": 1.6, "w": 1.4}
		"fh": return {"hot": Color(1, 0.88, 0.62), "mid": Color(1, 0.55, 0.18), "tail": Color(0.45, 0.2, 0.08), "len": 1.0, "w": 1.0}
		"shuttle": return {"hot": Color(0.85, 0.9, 1.0), "mid": Color(0.55, 0.6, 1.0), "tail": Color(0.2, 0.2, 0.5), "len": 1.2, "w": 1.0}
	return {"hot": Color(1, 0.8, 0.55), "mid": Color(1, 0.42, 0.14), "tail": Color(0.55, 0.22, 0.08), "len": 1.0, "w": 1.0}

func _cone(p: Node3D, sh: Shader, layer: float, col: Dictionary) -> MeshInstance3D:
	var m := MeshInstance3D.new(); var cm := CylinderMesh.new(); cm.top_radius = 0.5; cm.bottom_radius = 1.0 if layer < 0.5 else 1.6; cm.height = 1.0; cm.radial_segments = 20; cm.rings = 8
	cm.cap_top = false; cm.cap_bottom = false; m.mesh = cm
	var mat := ShaderMaterial.new(); mat.shader = sh; mat.set_shader_parameter("layer", layer)
	mat.set_shader_parameter("hot", col.hot); mat.set_shader_parameter("mid", col.mid); mat.set_shader_parameter("tail", col.tail)
	m.material_override = mat; m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF; m.visible = false
	m.set_meta("len", col.len); m.set_meta("w", col.w)
	p.add_child(m); return m

func _puffs(parent: Node3D, n: int, life: float, col: Color, s0: float, s1: float) -> GPUParticles3D:
	var p := GPUParticles3D.new(); p.amount = n; p.lifetime = life; p.emitting = false; p.local_coords = true
	p.visibility_aabb = AABB(Vector3(-3000, -500, -3000), Vector3(6000, 60000, 6000))
	var pm := ParticleProcessMaterial.new(); pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE; pm.emission_sphere_radius = 3.0
	pm.scale_min = s0; pm.scale_max = s0 * 1.6
	var cv := Curve.new(); cv.add_point(Vector2(0, 0.35)); cv.add_point(Vector2(1, s1 / s0)); var ct := CurveTexture.new(); ct.curve = cv; pm.scale_curve = ct
	var gr := Gradient.new(); gr.set_color(0, Color(1, 1, 1, 0.0)); gr.add_point(0.08, Color(1, 1, 1, 1)); gr.set_color(gr.get_point_count() - 1, Color(1, 1, 1, 0.0)); var gt := GradientTexture1D.new(); gt.gradient = gr; pm.color_ramp = gt
	p.process_material = pm
	var q := QuadMesh.new(); var sm := StandardMaterial3D.new(); sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES; sm.billboard_keep_scale = true
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA; sm.albedo_color = col; sm.albedo_texture = _puff_tex(); sm.vertex_color_use_as_albedo = true
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX; sm.proximity_fade_enabled = true; sm.proximity_fade_distance = 3.0
	q.material = sm; p.draw_pass_1 = q; p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(p); return p

static var _pt: ImageTexture
func _puff_tex() -> ImageTexture:
	if _pt: return _pt
	var img := Image.create(96, 96, false, Image.FORMAT_RGBA8); var nz := FastNoiseLite.new(); nz.frequency = 0.08
	for y in 96:
		for x in 96:
			var d := Vector2(x - 47.5, y - 47.5).length() / 48.0
			var a := clampf(1.0 - d, 0.0, 1.0); a = a * a * (0.65 + 0.35 * (nz.get_noise_2d(x, y) * 0.5 + 0.5))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_pt = ImageTexture.create_from_image(img); return _pt

func _burning(grp: String) -> bool:
	var st: int = g.stage
	if st == 9 or g.throttle <= 0.01: return false
	match grp:
		"bst": return st == 0
		"core": return st <= 1
		"s2": return st == 2 and sep_t >= 0.0 and g.T - sep_t > 2.0
	return false

func tick(dt: float) -> void:
	if g.stage == 2 and _last_stage < 2: sep_t = g.T
	_last_stage = g.stage
	var thin := smoothstep(0.0, 50000.0, g.alt)
	var any := false
	for e in plumes:
		var p: Node3D = e[0]; var on := _burning(e[3]) and p.is_inside_tree()
		for d in g.detached: if (d[0] as Node).is_ancestor_of(p): on = false
		var core: MeshInstance3D = e[1]; var outer: MeshInstance3D = e[2]
		core.visible = on; outer.visible = on
		if not on: continue
		any = true
		var thr: float = g.throttle
		var L: float = (24.0 + 40.0 * thin) * thr * float(core.get_meta("len")); var w: float = (1.0 + 7.0 * thin) * float(core.get_meta("w"))
		core.scale = Vector3(0.7, L * 0.45, 0.7); core.position = Vector3(0, -L * 0.225, 0)
		outer.scale = Vector3(w, L, w); outer.position = Vector3(0, -L * 0.5, 0)
		for m in [core, outer]:
			var sm: ShaderMaterial = m.material_override; sm.set_shader_parameter("thin", thin); sm.set_shader_parameter("power", thr * (0.9 + randf() * 0.2))
	light.light_energy = (2.5 * g.throttle * (0.85 + randf() * 0.3) if any else 0.0) * (1.0 - thin * 0.8)
	var T: float = g.T
	deluge.emitting = T > -16.0 and T < 25.0 and not g.lifted or (g.lifted and T < 12.0)
	smoke.emitting = T > -3.0 and T < 22.0 and g.throttle > 0.05
	steam.emitting = T > -2.0 and T < 14.0 and g.throttle > 0.05
	# exhaust trail: puffs dropped at the nozzle in the site frame; they swell and fade over ~70 s
	if g.lifted and g.alt < 32000.0 and any and g.stage < 3:
		_trail_acc += dt * (14.0 if mobile else 30.0)
		var base: Vector3 = g.site.to_local(g.rocket.global_position - g.rocket.global_transform.basis.y * 14.0)
		while _trail_acc >= 1.0:
			_trail_acc -= 1.0
			tr_pos[tr_i] = base + Vector3(randf_range(-2, 2), randf_range(-8, 0), randf_range(-2, 2)); tr_age[tr_i] = 0.0; tr_i = (tr_i + 1) % tr_n
	for i in tr_n:
		var a: float = tr_age[i]
		if a > 90.0: continue
		a += dt; tr_age[i] = a
		var sc := 6.0 + a * 1.6
		var p: Vector3 = tr_pos[i] + Vector3(1.5, 0.15, 0.6) * a
		tr_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(sc, sc, sc)), p))
		tr_mm.set_instance_color(i, Color(0.93, 0.93, 0.91, 0.55 * smoothstep(0.0, 1.5, a) * (1.0 - smoothstep(30.0, 90.0, a))))
	# vapour cone around Mach 0.9-1.2
	var mach: float = g.vel / 320.0
	var va := smoothstep(0.85, 1.0, mach) * (1.0 - smoothstep(1.1, 1.3, mach)) * (1.0 - smoothstep(9000.0, 14000.0, g.alt))
	vapour.visible = va > 0.01
	if vapour.visible: (vapour.material_override as StandardMaterial3D).albedo_color.a = va * 0.55

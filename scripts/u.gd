## Procedural geometry & material helpers shared by every builder.
class_name U
extends RefCounted

static var _cache := {}
static var font: Font = null
static func cjk() -> Font:
	if font == null: font = load("res://fonts/qh_cjk.ttf")
	return font

# ---------- materials ----------
static func noise_tex(freq: float, normal := false, seed := 1, size := 512, octaves := 5, bump := 2.0) -> NoiseTexture2D:
	var key := "n%s_%s_%s_%s_%s" % [freq, normal, seed, size, bump]
	if _cache.has(key): return _cache[key]
	var n := FastNoiseLite.new()
	n.seed = seed; n.frequency = freq; n.fractal_octaves = octaves; n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	var t := NoiseTexture2D.new()
	t.width = size; t.height = size; t.seamless = true; t.noise = n
	if normal: t.as_normal_map = true; t.bump_strength = bump
	_cache[key] = t
	return t

static func mat(col: Color, rough := 0.6, metal := 0.0, detail := 0.0, uv := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col; m.roughness = rough; m.metallic = metal
	if detail > 0.0:
		m.normal_enabled = true; m.normal_texture = noise_tex(0.02, true, 7, 512, 5, detail); m.normal_scale = 0.6
		m.roughness_texture = noise_tex(0.015, false, 3); m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.uv1_scale = Vector3(uv, uv, uv); m.uv1_triplanar = false
	return m

static func tri_mat(col: Color, rough := 0.8, metal := 0.0, scale := 0.25, bump := 3.0) -> StandardMaterial3D:
	# triplanar detail for big surfaces (concrete, sand, rock) so no UVs are needed
	var m := mat(col, rough, metal)
	m.normal_enabled = true; m.normal_texture = noise_tex(0.06, true, 11, 512, 6, bump); m.normal_scale = 0.45
	m.roughness_texture = noise_tex(0.02, false, 5); m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.uv1_triplanar = true; m.uv1_world_triplanar = true; m.uv1_scale = Vector3(scale, scale, scale)
	m.detail_enabled = true; m.detail_albedo = noise_tex(0.004, false, 21, 512, 3); m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_1
	return m

static func emissive(col: Color, energy := 4.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col; m.emission_enabled = true; m.emission = col; m.emission_energy_multiplier = energy
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

static func glass() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.66, 0.72, 0.18); m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.04; m.metallic = 0.9; m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

static func shader_mat(path: String, params := {}) -> ShaderMaterial:
	var m := ShaderMaterial.new(); m.shader = load(path)
	for k in params: m.set_shader_parameter(k, params[k])
	return m

# ---------- primitive placement ----------
static func put(parent: Node, mesh: Mesh, mat_: Material, pos := Vector3.ZERO, rot := Vector3.ZERO, shadow := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new(); mi.mesh = mesh
	if mat_: mi.material_override = mat_
	mi.position = pos; mi.rotation = rot
	if not shadow: mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi); return mi

static func box(parent: Node, size: Vector3, pos: Vector3, m: Material, rot := Vector3.ZERO, shadow := true) -> MeshInstance3D:
	var b := BoxMesh.new(); b.size = size
	return put(parent, b, m, pos, rot, shadow)

static func cyl(parent: Node, rt: float, rb: float, h: float, pos: Vector3, m: Material, seg := 32, rot := Vector3.ZERO, caps := true) -> MeshInstance3D:
	var c := CylinderMesh.new(); c.top_radius = rt; c.bottom_radius = rb; c.height = h; c.radial_segments = seg; c.rings = 1
	c.cap_top = caps; c.cap_bottom = caps
	return put(parent, c, m, pos, rot)

static func sphere(parent: Node, r: float, pos: Vector3, m: Material, seg := 24) -> MeshInstance3D:
	var s := SphereMesh.new(); s.radius = r; s.height = r * 2.0; s.radial_segments = seg; s.rings = seg / 2
	return put(parent, s, m, pos)

static func basis_from_y(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var x := Vector3.UP.cross(y)
	if x.length() < 0.01: x = Vector3.RIGHT.cross(y)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)

static func beam(parent: Node, a: Vector3, b: Vector3, r: float, m: Material, seg := 8) -> MeshInstance3D:
	var c := CylinderMesh.new(); c.top_radius = r; c.bottom_radius = r; c.height = a.distance_to(b); c.radial_segments = seg; c.rings = 1
	var mi := put(parent, c, m)
	mi.transform = Transform3D(basis_from_y(b - a), (a + b) * 0.5)
	return mi

## many identical struts in one draw call: segs = Array of [a, b]
static func struts(parent: Node, segs: Array, w: float, m: Material, square := true) -> MultiMeshInstance3D:
	var mesh: Mesh
	if square:
		var bm := BoxMesh.new(); bm.size = Vector3(w, 1, w); mesh = bm
	else:
		var cm := CylinderMesh.new(); cm.top_radius = w * 0.5; cm.bottom_radius = w * 0.5; cm.height = 1; cm.radial_segments = 6; cm.rings = 1; mesh = cm
	var mm := MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = mesh; mm.instance_count = segs.size()
	for i in segs.size():
		var a: Vector3 = segs[i][0]; var b: Vector3 = segs[i][1]
		var bs := basis_from_y(b - a); bs.y *= a.distance_to(b)
		mm.set_instance_transform(i, Transform3D(bs, (a + b) * 0.5))
	var mmi := MultiMeshInstance3D.new(); mmi.multimesh = mm; mmi.material_override = m
	parent.add_child(mmi); return mmi

# ---------- lathe (surface of revolution), the workhorse for rocket parts ----------
## prof: Array of Vector2(radius, y); smooth normals; u = angle, v = arc length (metres) so shaders can draw panel lines
static func lathe(prof: PackedVector2Array, seg := 64, phi0 := 0.0, phi1 := TAU, flip := false) -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var arc := PackedFloat32Array([0.0])
	for i in range(1, prof.size()): arc.append(arc[i - 1] + prof[i].distance_to(prof[i - 1]))
	# profile normals (2D) averaged at joints
	var n2 := []
	for i in prof.size():
		var t := Vector2.ZERO
		if i > 0: t += (prof[i] - prof[i - 1]).normalized()
		if i < prof.size() - 1: t += (prof[i + 1] - prof[i]).normalized()
		t = t.normalized(); n2.append(Vector2(t.y, -t.x) * (-1.0 if flip else 1.0))
	for s in seg:
		for k in 2:
			pass
	for s in seg:
		var a0 := phi0 + (phi1 - phi0) * float(s) / seg; var a1 := phi0 + (phi1 - phi0) * float(s + 1) / seg
		for i in prof.size() - 1:
			var quad := [[a0, i], [a1, i], [a1, i + 1], [a0, i], [a1, i + 1], [a0, i + 1]]
			if flip: quad = [[a0, i], [a1, i + 1], [a1, i], [a0, i], [a0, i + 1], [a1, i + 1]]
			for q in quad:
				var ang: float = q[0]; var j: int = q[1]
				var p: Vector2 = prof[j]; var nn: Vector2 = n2[j]
				st.set_normal(Vector3(sin(ang) * nn.x, nn.y, cos(ang) * nn.x).normalized())
				st.set_uv(Vector2(ang / TAU, arc[j]))
				st.add_vertex(Vector3(sin(ang) * p.x, p.y, cos(ang) * p.x))
	st.generate_tangents()
	return st.commit()

static func ring_pts(r0: float, r1: float, y0: float, y1: float, n := 2) -> PackedVector2Array:
	var p := PackedVector2Array()
	for i in n: p.append(Vector2(lerpf(r0, r1, float(i) / (n - 1)), lerpf(y0, y1, float(i) / (n - 1))))
	return p

## ogive/von-Karman nose profile from radius r at y0 to a point h above
static func nose_prof(r: float, y0: float, h: float, n := 16, tip := 0.04) -> PackedVector2Array:
	var p := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / n
		var th := acos(1.0 - 2.0 * t)
		var rr: float = r * sqrt((th - sin(2.0 * th) / 2.0) / PI)
		p.append(Vector2(maxf(rr, tip * r) if i < n else 0.0, y0 + h * (1.0 - t)))
	p.reverse()
	return p

## engine bell profile (parabolic), throat radius rt at y0 down to exit radius re at y0 - L
static func bell_prof(rt: float, re: float, L: float, y0: float, n := 14) -> PackedVector2Array:
	var p := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / n
		p.append(Vector2(rt + (re - rt) * pow(t, 0.62), y0 - L * t))
	return p

static func label(parent: Node, text: String, pos: Vector3, size := 0.5, col := Color.BLACK, rot := Vector3.ZERO, px := 128) -> Label3D:
	var l := Label3D.new(); l.font = cjk(); l.text = text; l.font_size = px; l.pixel_size = size / px; l.modulate = col
	l.outline_size = 0; l.position = pos; l.rotation = rot; l.double_sided = false
	l.shaded = true; l.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
	parent.add_child(l); return l

## rounded box (cushions, seat shells, suit parts): subdivided box pushed onto a rounded shape
static func rbox_mesh(size: Vector3, r: float, sub := 4) -> ArrayMesh:
	var key := "rb%s_%s_%s" % [size, r, sub]
	if _cache.has(key): return _cache[key]
	var bm := BoxMesh.new(); bm.size = size; bm.subdivide_width = sub; bm.subdivide_height = sub; bm.subdivide_depth = sub
	var arr := bm.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]; var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var inner := size * 0.5 - Vector3(r, r, r)
	inner = Vector3(maxf(inner.x, 0.0), maxf(inner.y, 0.0), maxf(inner.z, 0.0))
	for i in v.size():
		var p := v[i]; var c := Vector3(clampf(p.x, -inner.x, inner.x), clampf(p.y, -inner.y, inner.y), clampf(p.z, -inner.z, inner.z))
		var d := p - c
		var nn := d.normalized() if d.length() > 1e-5 else n[i]
		v[i] = c + nn * r; n[i] = nn
	arr[Mesh.ARRAY_VERTEX] = v; arr[Mesh.ARRAY_NORMAL] = n; arr[Mesh.ARRAY_TANGENT] = null
	var am := ArrayMesh.new(); am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_cache[key] = am
	return am

static func rbox(parent: Node, size: Vector3, r: float, pos: Vector3, m: Material, rot := Vector3.ZERO, sub := 4) -> MeshInstance3D:
	return put(parent, rbox_mesh(size, r, sub), m, pos, rot)

## smooth tube along a Catmull-Rom curve through pts (cable bundles, hoses)
static func hose(parent: Node, pts: PackedVector3Array, r: float, m: Material, seg := 8, steps := 10) -> MeshInstance3D:
	var c := Curve3D.new()
	for p in pts: c.add_point(p)
	for i in c.point_count:
		var a: Vector3 = pts[maxi(i - 1, 0)]; var b: Vector3 = pts[mini(i + 1, pts.size() - 1)]
		c.set_point_in(i, (a - b) * 0.2); c.set_point_out(i, (b - a) * 0.2)
	var path := c.tessellate_even_length(5, r * 2.0)
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_x := Vector3.RIGHT
	var rings := []
	for i in path.size():
		var t: Vector3 = (path[mini(i + 1, path.size() - 1)] - path[maxi(i - 1, 0)]).normalized()
		var x := (prev_x - t * prev_x.dot(t)).normalized()
		if x.length() < 0.1: x = t.cross(Vector3.UP).normalized()
		prev_x = x; var y := t.cross(x)
		var ring := []
		for k in seg + 1:
			var a := TAU * k / seg; var nn := x * cos(a) + y * sin(a)
			ring.append([path[i] + nn * r, nn, Vector2(float(k) / seg, float(i) * 0.1)])
		rings.append(ring)
	for i in rings.size() - 1:
		for k in seg:
			for q in [[i, k], [i + 1, k], [i + 1, k + 1], [i, k], [i + 1, k + 1], [i, k + 1]]:
				var e: Array = rings[q[0]][q[1]]
				st.set_normal(e[1]); st.set_uv(e[2]); st.add_vertex(e[0])
	return put(parent, st.commit(), m)

## orient a node in its PARENT's local space so -Z looks at target (positions are local, unlike Node3D.look_at)
static func aim(n: Node3D, pos: Vector3, target: Vector3, up := Vector3.UP) -> void:
	n.transform = Transform3D(Basis.looking_at(target - pos, up), pos)

static var _puff: ImageTexture
## soft round smoke puff (billboards)
static func puff_tex() -> ImageTexture:
	if _puff: return _puff
	var img := Image.create(96, 96, false, Image.FORMAT_RGBA8); var nz := FastNoiseLite.new(); nz.frequency = 0.08
	for y in 96:
		for x in 96:
			var d := Vector2(x - 47.5, y - 47.5).length() / 48.0
			var a := clampf(1.0 - d, 0.0, 1.0); a = a * a * (0.65 + 0.35 * (nz.get_noise_2d(x, y) * 0.5 + 0.5))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_puff = ImageTexture.create_from_image(img); return _puff

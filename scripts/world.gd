## Sky, sun, atmosphere and the Gobi-desert terrain around the launch site (Jiuquan-style).
class_name World
extends Node3D

var env: Environment
var sun: DirectionalLight3D
var sky_mat: PhysicalSkyMaterial
var terrain: MeshInstance3D
var noise := FastNoiseLite.new()
var ridge := FastNoiseLite.new()

func _ready() -> void:
	noise.seed = 4; noise.frequency = 0.0009; noise.fractal_octaves = 5
	ridge.seed = 9; ridge.frequency = 0.00011; ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED; ridge.fractal_octaves = 4; ridge.fractal_gain = 0.42
	_build_env()
	_build_terrain()

func _build_env() -> void:
	var we := WorldEnvironment.new(); env = Environment.new()
	sky_mat = PhysicalSkyMaterial.new()
	sky_mat.rayleigh_coefficient = 2.2; sky_mat.mie_coefficient = 0.006; sky_mat.mie_eccentricity = 0.82
	sky_mat.turbidity = 8.0; sky_mat.sun_disk_scale = 1.2; sky_mat.ground_color = Color(0.32, 0.27, 0.21); sky_mat.energy_multiplier = 1.0
	var sky := Sky.new(); sky.sky_material = sky_mat; sky.radiance_size = Sky.RADIANCE_SIZE_256
	env.sky = sky; env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; env.ambient_light_energy = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX; env.tonemap_exposure = 1.9
	env.ssao_enabled = true; env.ssao_radius = 1.6; env.ssao_intensity = 2.2; env.ssao_power = 1.6; env.ssao_detail = 0.6
	env.ssil_enabled = true; env.ssil_radius = 4.0; env.ssil_intensity = 0.8
	env.glow_enabled = true; env.glow_intensity = 0.55; env.glow_bloom = 0.04; env.glow_hdr_threshold = 1.2; env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_enabled = true; env.fog_mode = Environment.FOG_MODE_EXPONENTIAL; env.fog_density = 0.000022; env.fog_aerial_perspective = 0.85
	env.fog_sky_affect = 0.15; env.fog_light_color = Color(0.72, 0.78, 0.88); env.fog_sun_scatter = 0.25
	env.volumetric_fog_enabled = true; env.volumetric_fog_density = 0.0016; env.volumetric_fog_albedo = Color(0.9, 0.88, 0.84)
	env.volumetric_fog_length = 320.0; env.volumetric_fog_anisotropy = 0.6; env.volumetric_fog_sky_affect = 0.0
	env.adjustment_enabled = true; env.adjustment_contrast = 1.06; env.adjustment_saturation = 1.05
	if OS.has_feature("mobile"):
		env.volumetric_fog_enabled = false; env.ssil_enabled = false; env.ssao_radius = 1.2
	we.environment = env; add_child(we)
	sun = DirectionalLight3D.new(); sun.light_energy = 1.6; sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true; sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 600.0 if OS.has_feature("mobile") else 900.0; sun.directional_shadow_split_1 = 0.03; sun.directional_shadow_split_2 = 0.12; sun.directional_shadow_split_3 = 0.4
	sun.shadow_blur = 1.2; sun.light_angular_distance = 0.53; sun.shadow_bias = 0.03; sun.shadow_normal_bias = 1.2
	sun.light_volumetric_fog_energy = 1.0
	add_child(sun)
	set_sun(38.0, 128.0)

## elevation & azimuth in degrees
func set_sun(elev: float, az: float) -> void:
	sun.rotation_degrees = Vector3(-elev, az, 0)

# ---------- terrain ----------
var grid := PackedFloat32Array()
const GN := 1025
const GEXT := 60000.0
## eroded heightfield baked offline by gen/finish_terrain.py (1025^2 over +-60 km, row = z)
func height(x: float, z: float) -> float:
	if grid.is_empty():
		var f := FileAccess.open("res://gen/height.bin", FileAccess.READ)
		grid = f.get_buffer(f.get_length()).to_float32_array()
	var u := clampf((x + GEXT) / (2.0 * GEXT) * (GN - 1), 0.0, GN - 1.001); var v := clampf((z + GEXT) / (2.0 * GEXT) * (GN - 1), 0.0, GN - 1.001)
	var i := int(u); var j := int(v); var fu := u - i; var fv := v - j
	var h00 := grid[j * GN + i]; var h10 := grid[j * GN + i + 1]; var h01 := grid[(j + 1) * GN + i]; var h11 := grid[(j + 1) * GN + i + 1]
	var hh := lerpf(lerpf(h00, h10, fu), lerpf(h01, h11, fu), fv)
	var d := sqrt(x * x + z * z)
	return hh + noise.get_noise_2d(x * 3.0, z * 3.0) * 1.2 * smoothstep(1800.0, 5000.0, d) - d * d / (2.0 * 6371000.0)   # Earth curvature (matches the shader)

func make_terrain_mesh() -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var A := 640; var rings := PackedFloat32Array()
	var r := 0.0; var dr := 6.0
	while r < 60000.0:
		rings.append(r); r += dr; dr = minf(dr * 1.035, 150.0)
	var e := 2.0; var n_r := rings.size()
	for i in n_r:
		for a in A:
			var ang := TAU * a / A + (0.5 * TAU / A if i % 2 == 1 else 0.0)
			var x := sin(ang) * rings[i]; var z := cos(ang) * rings[i]; var y := height(x, z)
			e = maxf(2.0, rings[i] * 0.01)
			var nx := height(x - e, z) - height(x + e, z); var nz := height(x, z - e) - height(x, z + e)
			var n := Vector3(nx, 2.0 * e, nz).normalized()
			var rock: float = clampf((1.0 - n.y) * 5.0 + smoothstep(250.0, 700.0, y), 0.0, 1.0)
			st.set_color(Color(rock, clampf(y / 2600.0, 0.0, 1.0), clampf(rings[i] / 3000.0, 0.0, 1.0), 1))
			st.set_normal(n); st.set_uv(Vector2(x, z) * 0.05); st.add_vertex(Vector3(x, y, z))
	for i in n_r - 1:
		for a in A:
			var b := (a + 1) % A
			var i0 := i * A + a; var i1 := (i + 1) * A + a; var i2 := (i + 1) * A + b; var i3 := i * A + b
			st.add_index(i0); st.add_index(i2); st.add_index(i1); st.add_index(i0); st.add_index(i3); st.add_index(i2)
	st.generate_tangents()
	return st.commit()

func _build_terrain() -> void:
	var mesh: Mesh = load("res://gen/terrain.res") if ResourceLoader.exists("res://gen/terrain.res") else make_terrain_mesh()
	terrain = MeshInstance3D.new(); terrain.mesh = mesh
	terrain.material_override = U.shader_mat("res://shaders/terrain.gdshader", {"nz": U.noise_tex(0.01, false, 31, 1024, 6), "nn": U.noise_tex(0.02, true, 32, 1024, 6, 4.0), "macro_col": load("res://tex/terrain/macro_color.png"), "macro_nrm": load("res://tex/terrain/macro_normal.png"), "t_grass": load("res://tex/terrain/grass.jpg"), "t_gsnow": load("res://tex/terrain/grass_snow.jpg"), "t_snow": load("res://tex/terrain/snow.jpg"), "t_srock": load("res://tex/terrain/snow_rock.jpg")})
	terrain.extra_cull_margin = 2000.0
	add_child(terrain)
	# walkable collision for the levelled site
	var body := StaticBody3D.new(); var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = Vector3(4000, 2, 4000)
	cs.shape = bs; cs.position.y = -1.0; body.add_child(cs); add_child(body)

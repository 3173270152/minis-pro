## Earth seen from altitude: NASA Blue Marble surface, night lights, cloud shell and an atmospheric limb.
## Lives in the launch-site frame: the pad is at the north-pole-like top point of the sphere (0, 0, 0), centre at (0, -R, 0).
class_name Earth
extends Node3D

const R := 6371000.0
var surf: MeshInstance3D
var clouds: MeshInstance3D
var atmo: MeshInstance3D
var mat_s: ShaderMaterial
var mat_c: ShaderMaterial
var mat_a: ShaderMaterial

func _ready() -> void:
	top_level = true
	# rotate the globe so Jiuquan (40.96 N, 100.3 E) sits under the pad
	var lat := deg_to_rad(40.96); var lon := deg_to_rad(100.3)
	var b := Basis(Vector3.UP, -lon - PI)
	b = Basis(Vector3.RIGHT, -(PI * 0.5 - lat)) * b
	var sp := SphereMesh.new(); sp.radius = R * 1.004; sp.height = R * 2.008; sp.radial_segments = 96; sp.rings = 48
	mat_s = U.shader_mat("res://shaders/earth.gdshader", {
		"day": load("res://tex/earth/2_no_clouds_4k.jpg"), "night": load("res://tex/earth/earth_lights_2048.png"),
		"water": load("res://tex/earth/water_4k.png"), "nrm": load("res://tex/earth/earth_normal_2048.jpg")})
	surf = U.put(self, sp, mat_s); surf.basis = b; surf.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var cs := SphereMesh.new(); cs.radius = R + 9000.0; cs.height = (R + 9000.0) * 2.0; cs.radial_segments = 160; cs.rings = 80
	mat_c = U.shader_mat("res://shaders/clouds.gdshader", {"clouds": load("res://tex/earth/fair_clouds_4k.png")})
	clouds = U.put(self, cs, mat_c); clouds.basis = b; clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var as_ := SphereMesh.new(); as_.radius = R + 100000.0; as_.height = (R + 100000.0) * 2.0; as_.radial_segments = 128; as_.rings = 64
	mat_a = U.shader_mat("res://shaders/atmo.gdshader", {"planet_r": R, "atmo_r": R + 100000.0})
	atmo = U.put(self, as_, mat_a); atmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for m in [surf, clouds, atmo]: m.extra_cull_margin = 16384.0
	set_fade(0.0)

## 0 = invisible (on the ground, local terrain shows), 1 = fully visible
func set_fade(f: float) -> void:
	visible = true
	var fc := clampf((f - 0.55) / 0.45, 0.0, 1.0)
	clouds.visible = fc > 0.001; atmo.visible = f > 0.001
	mat_c.set_shader_parameter("fade", fc); mat_a.set_shader_parameter("fade", f)

const K := 60.0
const R_EFF := R - 20.0   # analytic ground sphere sits just under the local terrain
## keep the globe within the camera's far plane: shrink it by K toward the camera (perspective is unchanged)
func place(cam_pos: Vector3, centre: Vector3) -> void:
	global_position = cam_pos + (centre - cam_pos) / K
	scale = Vector3.ONE / K
	for m in [mat_s, mat_c, mat_a]: m.set_shader_parameter("kscale", K)
	var rel := centre - cam_pos
	mat_s.set_shader_parameter("centre_rel", rel)
	mat_s.set_shader_parameter("cam_alt", maxf(1.0, rel.length() - R_EFF))
	mat_s.set_shader_parameter("r_eff", R_EFF)
	mat_s.set_shader_parameter("inv_b", Basis(surf.basis).orthonormalized().inverse())

func set_sun(dir: Vector3) -> void:
	for m in [mat_s, mat_c, mat_a]: m.set_shader_parameter("sun_dir", dir.normalized())

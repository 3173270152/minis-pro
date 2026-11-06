## Free-flight physics of the descent module (or abort stack) in the launch-site frame.
## Site frame: launch pad at the origin, +Y up, downrange +X, Earth centre at (0, -R, 0).
## Position is kept in doubles (px, py, pz) because entry starts ~3000 km uprange; velocity is a Vector3.
## Forces: inverse-square gravity, drag (ballistic coefficient m / CdA), lift (L/D, banked about the velocity vector),
## parachute drag, optional thrust. Fixed sub-steps so a pre-simulation predicts the real flight exactly.
extends RefCounted

const R := 6371000.0
const MU := 3.986004e14
const G0 := 9.80665
const STEP := 0.05

var px := 0.0
var py := 0.0
var pz := 0.0
var v := Vector3.ZERO
var mass := 3000.0
var cda := 3.8            # capsule body Cd*A (m^2)
var ld := 0.3             # lift-to-drag ratio (0 = ballistic)
var bank := 0.0           # bank angle (rad), 0 = full lift up
var guided := true
var chute_cda := 0.0      # parachute Cd*A currently inflated
var chute_goal := 0.0
var chute_rate := 0.0     # inflation speed (CdA per second)
var thrust := Vector3.ZERO  # extra acceleration (m/s^2), e.g. escape motor / retro
var t := 0.0              # flight time (s)
var g := 0.0              # aerodynamic load (g)
var gmax := 0.0
var q := 0.0              # dynamic pressure (Pa)
var heat := 0.0           # 0..~1.5 stagnation heating index for visuals
var mach := 0.0
var alt := 0.0            # altitude above the sphere
var lift_dir := Vector3.UP
var up := Vector3.UP
var aero := Vector3.ZERO

func copy() -> RefCounted:
	var f = get_script().new()
	for k in ["px", "py", "pz", "v", "mass", "cda", "ld", "bank", "guided", "chute_cda", "chute_goal", "chute_rate", "thrust", "t", "gmax"]:
		f.set(k, get(k))
	return f

func pos() -> Vector3: return Vector3(px, py, pz)
func set_pos(p: Vector3) -> void: px = p.x; py = p.y; pz = p.z

static func rho(h: float) -> float:
	if h > 160000.0: return 0.0
	if h < 11000.0: return 1.225 * exp(-h / 8800.0)
	return 0.351 * exp(-(h - 11000.0) / 7000.0)

static func sound(h: float) -> float:
	return 340.0 - 0.0041 * clampf(h, 0.0, 11000.0)

## orbital state at altitude h over the arc position phi (rad, downrange from the pad), moving downrange
func set_orbit(phi: float, h: float, speed: float, gamma := 0.0, z := 0.0) -> void:
	var r := R + h
	px = sin(phi) * r; py = cos(phi) * r - R; pz = z
	var radial := Vector3(sin(phi), cos(phi), 0); var horiz := Vector3(cos(phi), -sin(phi), 0)
	v = (horiz * cos(gamma) + radial * sin(gamma)) * speed

## rotate the whole state about the Earth's centre (Z axis) by angle a (moves it downrange by a*R)
func rotate_about_earth(a: float) -> void:
	var cx := px; var cy := py + R
	var c := cos(a); var s := sin(a)
	# rotation that maps phi -> phi + a (x = sin(phi) r, y' = cos(phi) r)
	var nx := cx * c + cy * s; var ny := -cx * s + cy * c
	px = nx; py = ny - R
	v = Vector3(v.x * c + v.y * s, -v.x * s + v.y * c, v.z)

func phi() -> float: return atan2(px, py + R)

## default entry guidance: lift up with periodic roll reversals (bank +-35 deg); ballistic vehicles spin (no lift)
func guidance() -> void:
	if not guided: bank = 0.0; return
	var rev := 1.0 if sin(t * 0.03) > 0.0 else -1.0
	bank = lerpf(bank, deg_to_rad(35.0) * rev, 0.02)

func step(dt := STEP) -> void:
	t += dt
	var r := Vector3(px, py + R, pz)
	var rr := r.length(); up = r / rr
	alt = rr - R
	var grav := -up * (MU / (rr * rr))
	var sp := v.length()
	var dens := rho(alt)
	q = 0.5 * dens * sp * sp
	mach = sp / sound(alt)
	if chute_cda < chute_goal: chute_cda = minf(chute_goal, chute_cda + chute_rate * dt)
	elif chute_cda > chute_goal: chute_cda = maxf(chute_goal, chute_cda - chute_rate * dt * 4.0)
	aero = Vector3.ZERO
	if sp > 0.01:
		var vh := v / sp
		aero = -vh * q * (cda + chute_cda) / mass
		if ld > 0.0 and chute_cda < 0.5:
			guidance()
			var n := up - vh * up.dot(vh)
			if n.length() > 1e-6:
				n = n.normalized(); var side := vh.cross(n)
				lift_dir = n * cos(bank) + side * sin(bank)
				aero += lift_dir * q * cda * ld / mass
	g = (aero + thrust).length() / G0
	gmax = maxf(gmax, g if t > 0.5 else 0.0)
	heat = clampf(sqrt(dens / 1.225) * pow(sp / 7000.0, 3.0) * 80.0, 0.0, 1.6)
	v += (grav + aero + thrust) * dt
	px += v.x * dt; py += v.y * dt; pz += v.z * dt

## simulate a copy until cond(f) is true (or max_t); returns the copy
func predict(cond: Callable, max_t := 4000.0) -> RefCounted:
	var f = copy()
	var t0: float = f.t
	while f.t - t0 < max_t:
		f.step()
		if cond.call(f): break
	return f

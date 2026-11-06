## Physics ascent: point mass in the Earth-centred downrange plane (x = downrange, y = up at the pad), inverse-square
## gravity, exponential atmosphere, Mach-dependent drag, thrust/Isp interpolated with ambient pressure, propellant burn,
## staging by depletion, gravity turn then closed-loop altitude/flight-path guidance to a ~200 km circular orbit.
class_name Flight
extends RefCounted

const MU := 3.986004418e14
const R := 6371000.0
const G0 := 9.80665
const TARGET_H := 200000.0

# per-vehicle data: n = engines in the stage, prop/dry = stage totals (kg), thrust per engine (N), Isp (s)
const VEH := {
	"qihang": {"st": [[4, 150800.0, 12800.0, 740000.0, 816000.0, 261.0, 289.0], [4, 186000.0, 9500.0, 740000.0, 816000.0, 261.0, 289.0], [1, 91000.0, 4800.0, 700000.0, 790000.0, 260.0, 300.0]], "pay": 8100.0, "fair": 2600.0, "les": 7600.0, "core_guided": false, "area": 8.8},
	"saturn": {"st": [[0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0], [5, 2160000.0, 131000.0, 6770000.0, 7770000.0, 263.0, 304.0], [5, 550000.0, 50000.0, 780000.0, 1033000.0, 200.0, 421.0]], "pay": 45000.0, "fair": 1800.0, "les": 4100.0, "core_guided": false, "area": 80.0},
	"fh": {"st": [[18, 700000.0, 44000.0, 845000.0, 914000.0, 282.0, 311.0], [9, 380000.0, 22000.0, 845000.0, 914000.0, 282.0, 311.0], [1, 107500.0, 4000.0, 700000.0, 981000.0, 200.0, 348.0]], "pay": 12500.0, "fair": 1500.0, "les": 0.0, "core_guided": false, "area": 31.0, "core_thr0": 0.55},
	"shuttle": {"st": [[2, 1180000.0, 174000.0, 12500000.0, 13800000.0, 242.0, 268.0], [3, 730000.0, 26500.0, 1860000.0, 2279000.0, 366.0, 452.0], [2, 10000.0, 1.0, 26700.0, 26700.0, 316.0, 316.0]], "pay": 100000.0, "fair": 0.0, "les": 0.0, "core_guided": true, "area": 120.0}}
var stages: Array = []
var payload := 8100.0
var fairing_m := 2600.0
var les_m := 7600.0
var core_guided := false
var area0 := 8.8
var core_thr0 := 1.0

var t := 0.0
var r := Vector2(0, R)
var v := Vector2.ZERO
var prop := [0.0, 0.0, 0.0]
var phase := 0            # 0 boosters+core, 1 core, 2 coast to sep, 3 second stage, 4 orbit
var les_on := true
var fair_on := true
var throttle := 1.0
var engine_out := 0       # number of engines lost (core/boosters)
var dir := Vector2(0, 1)  # thrust direction (also the vehicle axis)
var state := {}
var events: Array = []    # keys emitted this step
var _q_peak := 0.0
var _mach_done := false
var _maxq_done := false
var _sep_t := -1.0
var _cut := false
var _vern := false

func _init(kind := "qihang") -> void:
	var d: Dictionary = VEH.get(kind, VEH["qihang"])
	for a in d.st: stages.append({"n": a[0], "prop": a[1], "dry": a[2], "thr_sl": a[3], "thr_vac": a[4], "isp_sl": a[5], "isp_vac": a[6]})
	payload = d.pay; core_thr0 = d.get("core_thr0", 1.0); fairing_m = d.fair; les_m = d.les; core_guided = d.core_guided; area0 = d.area
	les_on = les_m > 0.0; fair_on = fairing_m > 0.0
	for i in 3: prop[i] = stages[i].prop
	_update_state(0.0)

func mass() -> float:
	var m := payload + (fairing_m if fair_on else 0.0) + (les_m if les_on else 0.0)
	if phase == 0: m += stages[0].dry + prop[0]
	if phase <= 2: m += stages[1].dry + prop[1]
	m += stages[2].dry + prop[2]
	return m

func alt() -> float: return r.length() - R

func atmo(h: float) -> Array:
	var rho := 1.225 * exp(-h / 8400.0) if h < 100000.0 else 1.225 * exp(-100000.0 / 8400.0) * exp(-(h - 100000.0) / 6000.0)
	var p := 101325.0 * exp(-h / 7900.0)
	var a := 340.0 - clampf(h, 0.0, 11000.0) * 0.0039 + clampf(h - 20000.0, 0.0, 30000.0) * 0.0015
	return [rho, p, a]

func cd(m: float) -> float:
	if m < 0.8: return 0.32
	if m < 1.15: return lerpf(0.32, 0.62, (m - 0.8) / 0.35)
	if m < 3.0: return lerpf(0.62, 0.34, (m - 1.15) / 1.85)
	return 0.3

func _engine(i: int, pres: float) -> Array:   # [thrust N, mdot kg/s]
	var s: Dictionary = stages[i]; var k := clampf(pres / 101325.0, 0.0, 1.0)
	var n: int = s.n
	if i == 1 and engine_out > 0: n = maxi(n - engine_out, 0)
	var thr: float = lerpf(s.thr_vac, s.thr_sl, k) * n
	var isp: float = lerpf(s.isp_vac, s.isp_sl, k)
	return [thr, thr / (isp * G0)]

func step(dt: float) -> void:
	events.clear()
	var sub := maxi(1, int(ceil(dt / (1.0 / 120.0)))); var h_ := dt / sub
	for k in sub: _sub(h_)
	_update_state(dt)

func _sub(dt: float) -> void:
	t += dt
	var h := alt(); var A := atmo(h); var rho: float = A[0]; var pres: float = A[1]; var snd: float = A[2]
	var up := r.normalized(); var east := Vector2(up.y, -up.x)
	var thrust := 0.0; var mdot := [0.0, 0.0, 0.0]
	if phase <= 1:
		if phase == 0:
			var e0 := _engine(0, pres); thrust += e0[0] * throttle; mdot[0] = e0[1] * throttle
		var ct := throttle * (core_thr0 if phase == 0 else 1.0)
		var e1 := _engine(1, pres); thrust += e1[0] * ct; mdot[1] = e1[1] * ct
	elif phase == 3 and not _cut:
		var e2 := _engine(2, pres); var thr2 := throttle * (1.0 if prop[2] > 2500.0 else 0.12)   # main engine cutoff, then verniers only
		if prop[2] <= 2500.0 and not _vern: _vern = true; events.append("vern")
		thrust += e2[0] * thr2; mdot[2] = e2[1] * thr2
	# guidance: vertical rise, pitch kick, gravity turn, then closed-loop on altitude & vertical speed
	var vr := v.dot(up); var vt := v.dot(east)
	var want := up
	if core_guided and phase == 1 and t > 150.0:
		var a_thr := thrust / mass(); var g_eff := MU / r.length_squared() - vt * vt / r.length()
		var vr_t := clampf((TARGET_H - h) * 0.005, -60.0, 260.0); var ay := clampf(0.12 * (vr_t - vr), -8.0, 8.0) + g_eff
		var s0 := clampf(ay / maxf(a_thr, 0.1), -0.4, 0.75); want = (up * s0 + east * sqrt(1.0 - s0 * s0)).normalized()
	elif t > 10.0 and phase <= 2:
		# stage-1 open-loop pitch program (as flown by Long March vehicles)
		var p := 90.0 - 52.0 * clampf((t - 10.0) / 110.0, 0.0, 1.0) - 20.0 * clampf((t - 120.0) / 40.0, 0.0, 1.0)
		var pr := deg_to_rad(p)
		want = (up * sin(pr) + east * cos(pr)).normalized()
	elif phase == 3:
		var a_thr := thrust / mass()
		var g_eff := MU / r.length_squared() - vt * vt / r.length()
		var vr_t := clampf((TARGET_H - h) * 0.005, -60.0, 260.0)
		var ay := clampf(0.12 * (vr_t - vr), -8.0, 8.0) + g_eff
		var s := clampf(ay / maxf(a_thr, 0.1), -0.4, 0.75)
		want = (up * s + east * sqrt(1.0 - s * s)).normalized()
	dir = dir.slerp(want, clampf(dt * 0.9, 0.0, 1.0)) if t > 1.0 else up
	# propellant
	for i in 3:
		prop[i] = maxf(0.0, prop[i] - mdot[i] * dt)
	var m := mass()
	var vel := v.length()
	var mach := vel / snd
	var area := area0 * (1.0 if phase == 0 else 0.55)
	var drag := 0.5 * rho * vel * vel * cd(mach) * area
	var acc := dir * thrust / m - r.normalized() * MU / r.length_squared()
	if vel > 0.1: acc -= v / vel * drag / m
	# held down on the pad until thrust > weight
	if h < 0.5 and acc.dot(up) <= 0.0 and t < 5.0: acc = Vector2.ZERO; v = Vector2.ZERO
	v += acc * dt; r += v * dt
	var q := 0.5 * rho * vel * vel
	state = {"thrust": thrust, "acc": acc, "q": q, "mach": mach, "mass": m}
	# events from physics
	if not _mach_done and mach >= 1.0: _mach_done = true; events.append("mach")
	if q > _q_peak: _q_peak = q
	elif not _maxq_done and _q_peak > 15000.0 and q < _q_peak * 0.97: _maxq_done = true; events.append("maxq")
	if les_on and t >= 120.0: les_on = false; events.append("lesj")
	if phase == 0 and stages[0].n == 0: phase = 1
	if phase == 0 and prop[0] <= 0.0: phase = 1; events.append("bsep")
	if phase == 1 and (prop[1] <= 0.0 or core_guided and vt >= sqrt(MU / r.length()) - 40.0): phase = 2; _sep_t = t; events.append("meco")
	if phase == 2 and t - _sep_t > 2.0: phase = 3; events.append("sep"); events.append("ses")
	if fair_on and h > 110000.0: fair_on = false; events.append("fair")
	if phase == 3 and not _cut:
		var vcirc := sqrt(MU / r.length())
		if vt >= vcirc - 3.0 or prop[2] <= 0.0:
			_cut = true; phase = 4; events.append("seco")
			if prop[2] <= 0.0 and vt < vcirc - 50.0: events.append("underspeed")

func _update_state(_dt: float) -> void:
	var up := r.normalized(); var east := Vector2(up.y, -up.x)
	var acc: Vector2 = state.get("acc", Vector2.ZERO)
	var sensed := acc + up * MU / r.length_squared()                    # what an accelerometer feels
	if alt() < 1.0 and v.length() < 0.1: sensed = up * G0
	state["pos"] = Vector3(r.x, r.y - R, 0.0)
	state["vel"] = Vector3(v.x, v.y, 0.0)
	state["alt"] = alt(); state["speed"] = v.length(); state["g"] = sensed.length() / G0
	state["pitch"] = rad_to_deg(asin(clampf(dir.dot(up), -1.0, 1.0)))
	state["vr"] = v.dot(up); state["vt"] = v.dot(east); state["phase"] = phase; state["dir"] = Vector3(dir.x, dir.y, 0.0)
	var rv := r.length(); var en := v.length_squared() * 0.5 - MU / rv; var a := -MU / (2.0 * en) if en < 0.0 else 1e12
	var hmom := absf(r.x * v.y - r.y * v.x); var e := sqrt(maxf(0.0, 1.0 + 2.0 * en * hmom * hmom / (MU * MU)))
	state["apo"] = a * (1.0 + e) - R; state["peri"] = a * (1.0 - e) - R

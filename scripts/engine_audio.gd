## Launch & cabin audio: ignition sequence (turbopump whine, ignition thump), deep rumble + band roar + supersonic crackle,
## cabin-filtered version with structural vibration, silence in vacuum; cabin machinery driven by the console; switch sounds.
extends Node

var g
var rumble: AudioStreamPlayer
var roar: AudioStreamPlayer
var crackle: AudioStreamPlayer
var fans: AudioStreamPlayer
var whine400: AudioStreamPlayer
var one: AudioStreamPlayer
var clicks := {}
var ign_done := false
var whine_done := false
var lift_done := false
var _last_stage := 0
const RATE := 22050

func setup(game) -> void:
	g = game
	_bus("EngAudio", 6000.0)
	rumble = _loop(_noise(4.0, 0.996, 1.0)); roar = _loop(_noise(3.0, 0.92, 0.7)); crackle = _loop(_crackle(3.0))
	fans = _loop(_noise(2.0, 0.6, 0.5), "Master"); whine400 = _loop(_tone(400.0, 1.0, 0.25), "Master")
	one = AudioStreamPlayer.new(); one.bus = "EngAudio"; add_child(one)
	clicks = {"t": _click(0.004, 2600.0, 0.9), "c": _click(0.012, 700.0, 1.0), "p": _click(0.003, 1800.0, 0.6), "g": _click(0.006, 1200.0, 0.8)}
	if g.console: g.console.changed.connect(_on_changed)

func _bus(name: String, lp: float) -> void:
	if AudioServer.get_bus_index(name) >= 0: return
	AudioServer.add_bus(); var i := AudioServer.bus_count - 1; AudioServer.set_bus_name(i, name)
	var f := AudioEffectLowPassFilter.new(); f.cutoff_hz = lp; AudioServer.add_bus_effect(i, f)

func _wav(s: PackedFloat32Array, loop := true) -> AudioStreamWAV:
	var data := PackedByteArray(); data.resize(s.size() * 2)
	for i in s.size(): data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new(); w.format = AudioStreamWAV.FORMAT_16_BITS; w.mix_rate = RATE; w.data = data
	if loop: w.loop_mode = AudioStreamWAV.LOOP_FORWARD; w.loop_end = s.size()
	return w

func _norm(s: PackedFloat32Array, peak := 0.9) -> PackedFloat32Array:
	var m := 1e-5
	for v in s: m = maxf(m, absf(v))
	for i in s.size(): s[i] = s[i] / m * peak
	return s

func _noise(sec: float, k: float, hp: float) -> AudioStreamWAV:
	var n := int(RATE * sec); var s := PackedFloat32Array(); s.resize(n); var l := 0.0; var prev := 0.0
	for i in n:
		l = l * k + randf_range(-1.0, 1.0) * (1.0 - k)
		var o := l - prev * (1.0 - hp) * 0.0; prev = l; s[i] = o
	var x := 3000
	for i in x: var a := float(i) / x; s[i] = s[i] * a + s[n - x + i] * (1.0 - a)
	return _wav(_norm(s.slice(0, n - x)))

## supersonic jet crackle: sparse sharp N-wave shocks with random amplitude
func _crackle(sec: float) -> AudioStreamWAV:
	var n := int(RATE * sec); var s := PackedFloat32Array(); s.resize(n)
	var i := 0
	while i < n:
		i += int(-log(1.0 - randf()) * RATE / 260.0) + 1
		var a := pow(randf(), 2.2) * (1.0 if randf() < 0.5 else -1.0); var L := 8 + randi() % 40
		for j in L:
			if i + j < n: s[i + j] += a * (1.0 - 2.0 * float(j) / L) * exp(-float(j) / L)
	return _wav(_norm(s, 0.95))

func _tone(f: float, sec: float, noise: float) -> AudioStreamWAV:
	var n := int(RATE * sec); var s := PackedFloat32Array(); s.resize(n)
	for i in n: s[i] = sin(TAU * f * i / RATE) * 0.5 + sin(TAU * f * 2.0 * i / RATE) * 0.15 + randf_range(-noise, noise) * 0.2
	return _wav(s)

func _click(dur: float, f: float, v: float) -> AudioStreamWAV:
	var n := int(RATE * (dur + 0.04)); var s := PackedFloat32Array(); s.resize(n)
	for i in n:
		var t := float(i) / RATE; var e := exp(-t / dur)
		s[i] = (sin(TAU * f * t) * 0.5 + randf_range(-1, 1) * 0.5) * e * v + sin(TAU * 140.0 * t) * exp(-t / 0.02) * 0.3 * v
	return _wav(s, false)

func _sweep(sec: float, f0: float, f1: float) -> AudioStreamWAV:
	var n := int(RATE * sec); var s := PackedFloat32Array(); s.resize(n); var ph := 0.0
	for i in n:
		var t := float(i) / n; var f := lerpf(f0, f1, t * t); ph += TAU * f / RATE
		s[i] = sin(ph) * 0.35 * smoothstep(0.0, 0.2, t) + randf_range(-0.15, 0.15) * t
	return _wav(s, false)

func _boom() -> AudioStreamWAV:
	var n := int(RATE * 2.0); var s := PackedFloat32Array(); s.resize(n); var l := 0.0
	for i in n:
		var t := float(i) / RATE; l = l * 0.97 + randf_range(-1, 1) * 0.03
		s[i] = (sin(TAU * 38.0 * t) * 0.8 + l * 6.0) * exp(-t * 2.2)
	return _wav(_norm(s), false)

func _loop(st: AudioStream, bus := "EngAudio") -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new(); p.stream = st; p.bus = bus; p.volume_db = -80.0; add_child(p); p.play(); return p

func _shot(st: AudioStream, db := 0.0) -> void:
	one.stream = st; one.volume_db = db; one.play()

func _on_changed(id: String) -> void:
	var k: String = g.console.kind_of(id) if (g.console.SW.has(id) or id.begins_with("cb")) else "p"
	var p := AudioStreamPlayer.new(); p.stream = clicks.get(k, clicks["t"]); p.pitch_scale = randf_range(0.92, 1.1); p.volume_db = -4.0
	add_child(p); p.play(); p.finished.connect(p.queue_free)

func _db(v: float) -> float: return linear_to_db(maxf(v, 1e-4))

func tick(_dt: float) -> void:
	if g.sfx and g.sfx.engine and g.cfg.mode != "spectator": g.sfx.engine.volume_db = -80.0; g.sfx.rumble.volume_db = -80.0
	var T: float = g.T
	if T > -6.0 and not whine_done and g.throttle >= 0.0 and g.running: whine_done = true; _shot(_sweep(3.5, 180.0, 2400.0), -10.0)
	if g.throttle > 0.0 and not ign_done: ign_done = true; _shot(_boom(), 0.0)
	if g.stage != _last_stage and g.stage in [1, 2]: _shot(_boom(), -6.0)
	_last_stage = g.stage
	var inside: bool = g.cam_mode == "seat" or g.cam_mode == "module" and g.cfg.mode != "spectator"
	var thr: float = g.throttle if g.stage < 3 and g.stage != 9 else 0.0
	var air := 1.0 - smoothstep(20000.0, 60000.0, g.alt)          # sound needs air (outside) — inside only structure-borne
	var q := clampf(g.qdyn / 35000.0, 0.0, 1.0)
	var dist := 1.0
	if g.cfg.mode == "spectator": dist = 0.0   # spectator module sets its own engine level via sfx; keep ours quiet there
	var i := AudioServer.get_bus_index("EngAudio")
	(AudioServer.get_bus_effect(i, 0) as AudioEffectLowPassFilter).cutoff_hz = 380.0 if inside else 5000.0
	var lv := thr * dist
	rumble.volume_db = _db(lv * (1.0 if inside else air) * (0.9 + q * 0.4))
	roar.volume_db = _db(lv * (0.35 if inside else 0.8 * air) * (1.0 + q * 0.5))
	crackle.volume_db = _db(lv * (0.12 if inside else 0.75 * air) * (1.0 - smoothstep(0.0, 25.0, maxf(T, 0.0)) * 0.5))
	rumble.pitch_scale = 0.85 + thr * 0.2
	# cabin machinery (only meaningful inside)
	var c = g.console
	var fanl: float = (c.n_on(["CFAN1", "CFAN2"]) * 0.5 + c.n_on(["GLY1", "GLY2"]) * 0.3) if inside else 0.0
	fans.volume_db = _db(fanl * 0.12)
	whine400.volume_db = _db((0.02 if c.PW.AC else 0.0) if inside else 0.0)

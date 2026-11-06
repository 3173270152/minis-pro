## Audio: voice queue (radio / cabin / PA chains), synthesized engine roar & cabin machinery, UI clicks, master alarm.
class_name Sfx
extends Node

const SPK := {"DOC": ["航天医生", "cabin"], "DRV": ["大巴司机", "cabin"], "GC": ["地勤指挥", "cabin"], "DIR": ["发射指挥", "radio"], "CAP": ["指挥大厅", "radio"],
	"ME": ["指令长（你）", "me"], "C1": ["航天员 林悦", "cabin"], "C2": ["航天员 陈默", "cabin"], "ST": ["空间站 · 赵航", "radio"], "ST2": ["空间站 · 苏岚", "radio"],
	"TECH": ["白房间技师", "cabin"], "SR": ["搜救队", "radio"], "P1": ["推进岗位", "radio"], "P2": ["测控岗位", "radio"], "PA": ["现场广播", "pa"]}

signal subtitle(who: String, text: String, dur: float)

var queue: Array = []
var voice: AudioStreamPlayer
var busy_until := 0.0
var t := 0.0
var comm_ok := true
var engine: AudioStreamPlayer
var rumble: AudioStreamPlayer
var hum: AudioStreamPlayer
var alarm_p: AudioStreamPlayer
var click_p: AudioStreamPlayer
var _alarm_on := false

func _ready() -> void:
	_bus("Radio", [_bp(1800.0, 1.0), _dist(0.35), _hp(320.0)])
	_bus("Cabin", [_lp(9000.0)])
	_bus("Engine", [_lp(900.0)])
	voice = AudioStreamPlayer.new(); add_child(voice)
	engine = _loop(_noise(2.0, 0.985), "Engine", -80.0)
	rumble = _loop(_noise(3.0, 0.997), "Engine", -80.0)
	hum = _loop(_hum_stream(), "Cabin", -80.0)
	alarm_p = AudioStreamPlayer.new(); alarm_p.stream = _alarm_stream(); alarm_p.volume_db = -14.0; add_child(alarm_p)
	click_p = AudioStreamPlayer.new(); click_p.stream = _click_stream(); click_p.volume_db = -6.0; add_child(click_p)

# ---------- bus helpers ----------
func _bus(name: String, fx: Array) -> void:
	if AudioServer.get_bus_index(name) >= 0: return
	AudioServer.add_bus(); var i := AudioServer.bus_count - 1; AudioServer.set_bus_name(i, name)
	for e in fx: AudioServer.add_bus_effect(i, e)
func _bp(f: float, q: float) -> AudioEffectBandPassFilter:
	var e := AudioEffectBandPassFilter.new(); e.cutoff_hz = f; e.resonance = q; return e
func _lp(f: float) -> AudioEffectLowPassFilter:
	var e := AudioEffectLowPassFilter.new(); e.cutoff_hz = f; return e
func _hp(f: float) -> AudioEffectHighPassFilter:
	var e := AudioEffectHighPassFilter.new(); e.cutoff_hz = f; return e
func _dist(d: float) -> AudioEffectDistortion:
	var e := AudioEffectDistortion.new(); e.mode = AudioEffectDistortion.MODE_CLIP; e.drive = d; return e

# ---------- procedural streams ----------
func _wav(samples: PackedFloat32Array, rate := 22050, loop := true) -> AudioStreamWAV:
	var data := PackedByteArray(); data.resize(samples.size() * 2)
	for i in samples.size(): data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new(); w.format = AudioStreamWAV.FORMAT_16_BITS; w.mix_rate = rate; w.stereo = false; w.data = data
	if loop: w.loop_mode = AudioStreamWAV.LOOP_FORWARD; w.loop_end = samples.size()
	return w

func _noise(sec: float, k: float) -> AudioStreamWAV:
	var n := int(22050 * sec); var s := PackedFloat32Array(); s.resize(n); var l := 0.0
	for i in n: l = l * k + randf_range(-1.0, 1.0) * (1.0 - k) * 9.0; s[i] = l
	# crossfade loop ends
	for i in 2000: var a := float(i) / 2000.0; s[i] = s[i] * a + s[n - 2000 + i] * (1.0 - a)
	var m := 0.0
	for v in s: m = maxf(m, absf(v))
	for i in n: s[i] /= maxf(m, 1e-4) * 1.1
	return _wav(s.slice(0, n - 2000))

func _hum_stream() -> AudioStreamWAV:
	var n := 22050; var s := PackedFloat32Array(); s.resize(n); var l := 0.0
	for i in n:
		var tt := float(i) / 22050.0
		l = l * 0.9 + randf_range(-1, 1) * 0.1
		s[i] = sin(TAU * 118.0 * tt) * 0.15 + sin(TAU * 400.0 * tt) * 0.03 + l * 0.35
	return _wav(s)

func _alarm_stream() -> AudioStreamWAV:
	var n := int(22050 * 1.1); var s := PackedFloat32Array(); s.resize(n)
	for i in n:
		var tt := float(i) / 22050.0; var f := 880.0 if tt < 0.18 else (660.0 if tt > 0.22 and tt < 0.40 else 0.0)
		s[i] = (1.0 if fmod(tt * f, 1.0) < 0.5 else -1.0) * 0.4 if f > 0.0 else 0.0
	return _wav(s)

func _click_stream() -> AudioStreamWAV:
	var n := 900; var s := PackedFloat32Array(); s.resize(n)
	for i in n:
		var e := exp(-float(i) / 90.0)
		s[i] = (randf_range(-1, 1) * 0.6 + sin(float(i) * 0.8) * 0.4) * e
	return _wav(s, 22050, false)

func _loop(stream: AudioStream, bus: String, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new(); p.stream = stream; p.bus = bus; p.volume_db = db; add_child(p); p.play(); return p

# ---------- API ----------
func click() -> void: click_p.pitch_scale = randf_range(0.9, 1.15); click_p.play()
func set_alarm(on: bool) -> void:
	if on == _alarm_on: return
	_alarm_on = on
	if on: alarm_p.play()
	else: alarm_p.stop()

## thrust 0..1, inside = listening from the cabin
func set_engine(thrust: float, inside: bool, dyn_q := 0.0) -> void:
	var v := clampf(thrust, 0.0, 1.0)
	engine.volume_db = linear_to_db(maxf(v * (0.55 if inside else 1.0), 1e-4)) - 2.0
	rumble.volume_db = linear_to_db(maxf(v * 0.9 + dyn_q * 0.4, 1e-4))
	engine.pitch_scale = 0.8 + v * 0.3
	var i := AudioServer.get_bus_index("Engine")
	(AudioServer.get_bus_effect(i, 0) as AudioEffectLowPassFilter).cutoff_hz = 500.0 if inside else 2400.0

func set_hum(level: float) -> void: hum.volume_db = linear_to_db(maxf(level * 0.25, 1e-4))

func line(id: String, delay := 0.0, now := false) -> void:
	if not Lines.L.has(id): return
	if now: queue.clear(); voice.stop(); busy_until = 0.0
	queue.append({"id": id, "at": t + delay})

func _process(dt: float) -> void:
	t += dt
	if queue.is_empty() or t < busy_until: return
	var e = null
	for q in queue: if t >= q.at: e = q; break
	if e == null: return
	queue.erase(e)
	var L: Array = Lines.L[e.id]; var who: Array = SPK.get(L[0], ["", "cabin"])
	var kind: String = who[1]
	if kind == "radio" and not comm_ok:
		subtitle.emit("系统", "（通信链路关闭，收不到地面呼叫）", 2.0); return
	var st: AudioStream = load("res://audio/%s.mp3" % e.id)
	var dur := st.get_length() if st else 2.0
	voice.stream = st; voice.bus = "Radio" if kind == "radio" else ("Cabin" if kind != "pa" else "Master"); voice.volume_db = 2.0 if kind == "radio" else 0.0
	voice.play(); busy_until = t + dur + 0.35
	subtitle.emit(String(who[0]), String(L[1]), dur + 2.5)

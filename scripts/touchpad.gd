## Virtual left-thumb joystick + right-side look drag + tap detection (touch), mouse-drag look + click (desktop).
## The owner feeds every InputEvent through feed() and reads vec / takes look and taps each frame.
class_name CrewTouchpad
extends Control

const R := 74.0
var joy_id := -1
var joy_c := Vector2.ZERO
var joy_p := Vector2.ZERO
var look_id := -1
var look_from := Vector2.ZERO
var look_t0 := 0
var look_moved := 0.0
var mouse_down := false
var mouse_moved := 0.0
var vec := Vector2.ZERO        # x = right, y = forward, length 0..1
var look := Vector2.ZERO       # accumulated look drag in pixels (owner zeroes it)
var taps: Array = []           # tap positions (owner clears)
var show_stick := true
var touch := false

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch = DisplayServer.is_touchscreen_available()

func _zone(p: Vector2) -> bool:
	var s := get_viewport_rect().size
	return show_stick and p.x < s.x * 0.42 and p.y > s.y * 0.35

func feed(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		touch = true
		if e.pressed:
			if joy_id < 0 and _zone(e.position):
				joy_id = e.index; joy_c = e.position; joy_p = e.position
			elif look_id < 0:
				look_id = e.index; look_from = e.position; look_t0 = Time.get_ticks_msec(); look_moved = 0.0
		else:
			if e.index == joy_id:
				joy_id = -1; vec = Vector2.ZERO
			elif e.index == look_id:
				look_id = -1
				if look_moved < 16.0 and Time.get_ticks_msec() - look_t0 < 450: taps.append(e.position)
		queue_redraw()
	elif e is InputEventScreenDrag:
		if e.index == joy_id:
			joy_p = e.position
			var d: Vector2 = joy_p - joy_c
			if d.length() > R: joy_c = joy_p - d.normalized() * R; d = joy_p - joy_c   # floating stick follows the thumb
			vec = Vector2(d.x, -d.y) / R
			queue_redraw()
		elif e.index == look_id:
			look += e.relative; look_moved += e.relative.length()
	elif not touch and e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed: mouse_down = true; mouse_moved = 0.0
		else:
			mouse_down = false
			if mouse_moved < 6.0: taps.append(e.position)
	elif not touch and e is InputEventMouseMotion and mouse_down:
		look += e.relative * 0.8; mouse_moved += e.relative.length()

func _draw() -> void:
	if not touch or not show_stick: return
	var s := get_viewport_rect().size
	var c := joy_c if joy_id >= 0 else Vector2(150, s.y - 170)
	var k := joy_p if joy_id >= 0 else c
	draw_circle(c, R + 6.0, Color(0.05, 0.08, 0.12, 0.28))
	draw_arc(c, R + 6.0, 0, TAU, 48, Color(1, 1, 1, 0.35), 2.0, true)
	draw_circle(k, 30.0, Color(1, 1, 1, 0.42 if joy_id >= 0 else 0.22))
	if joy_id < 0:
		var f := get_theme_default_font()
		draw_string(f, c + Vector2(-26, R + 34), "移动", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 1, 1, 0.55))

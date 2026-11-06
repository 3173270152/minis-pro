## On-screen HUD: mission clock, telemetry, objective, subtitles, procedure book with guide buttons, C&W list,
## control tooltip and touch buttons. Built in code; scales with the window (canvas_items stretch).
class_name Hud
extends CanvasLayer

signal button(name: String)

var clock: Label
var phase_l: Label
var objective: Label
var sub_who: Label
var sub_txt: Label
var tip: Label
var garrow: Label
var tele: Label
var proc_box: PanelContainer
var proc_title: Label
var proc_list: RichTextLabel
var cw_list: RichTextLabel
var btn_guide: Button
var btn_crew: Button
var touch_row: HBoxContainer
var go_btn: Button
var cross: Label
var fps: Label
var _sub_until := 0.0
var _t := 0.0
var font_size := 22

func _ready() -> void:
	layer = 10
	var root := Control.new(); root.set_anchors_preset(Control.PRESET_FULL_RECT); root.mouse_filter = Control.MOUSE_FILTER_IGNORE; add_child(root)
	# keep everything clear of the notch / home indicator on phones
	var safe := DisplayServer.get_display_safe_area(); var win := DisplayServer.window_get_size()
	if win.x > 0 and safe.size.x > 0 and safe.size.x < win.x:
		var k := get_viewport().get_visible_rect().size.x / float(win.x)
		root.offset_left = safe.position.x * k; root.offset_right = -(win.x - safe.end.x) * k
		root.offset_top = safe.position.y * k; root.offset_bottom = -(win.y - safe.end.y) * k
	# mission clock (top-left)
	var tl := VBoxContainer.new(); tl.position = Vector2(28, 18); root.add_child(tl)
	var cap := _label(tl, "启航号 · 任务时间", 15, Color(0.6, 0.75, 0.9))
	clock = _label(tl, "T−00:01:00", 54, Color(0.95, 0.97, 1.0))
	phase_l = _label(tl, "计划内暂停 · HOLD", 18, Color(1.0, 0.72, 0.3))
	fps = _label(tl, "", 13, Color(0.6, 0.7, 0.8))
	# telemetry (top-right)
	tele = _label(root, "", 17, Color(0.85, 0.92, 1.0)); tele.set_anchors_preset(Control.PRESET_TOP_RIGHT); tele.position = Vector2(-250, 22); tele.size = Vector2(230, 160)
	tele.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# objective (top-centre)
	objective = _label(root, "", 19, Color(1, 1, 1)); objective.anchor_left = 0.24; objective.anchor_right = 0.76; objective.offset_left = 0; objective.offset_right = 0; objective.offset_top = 20; objective.offset_bottom = 90
	objective.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_shadow(objective)
	# subtitles (bottom-centre)
	var sb := VBoxContainer.new(); sb.set_anchors_preset(Control.PRESET_CENTER_BOTTOM); sb.position = Vector2(-460, -150); sb.size = Vector2(920, 100); root.add_child(sb)
	sub_who = _label(sb, "", 16, Color(1.0, 0.75, 0.35)); sub_who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_txt = _label(sb, "", 23, Color(1, 1, 1)); sub_txt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; sub_txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_shadow(sub_txt); _shadow(sub_who)
	# crosshair + control tooltip (centre)
	cross = _label(root, "·", 30, Color(1, 1, 1, 0.8)); cross.set_anchors_preset(Control.PRESET_CENTER); cross.position = Vector2(-6, -22)
	tip = _label(root, "", 16, Color(1, 1, 1)); tip.anchor_left = 0.5; tip.anchor_right = 0.5; tip.anchor_top = 0.5; tip.anchor_bottom = 0.5; tip.offset_left = -220; tip.offset_right = 220; tip.offset_top = 22; tip.offset_bottom = 82
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; _shadow(tip)
	garrow = _label(root, "➤", 44, Color(1.0, 0.85, 0.1)); garrow.size = Vector2(60, 60); garrow.pivot_offset = Vector2(30, 30); garrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; garrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER; garrow.visible = false; _shadow(garrow)
	# procedure book (right)
	proc_box = PanelContainer.new(); proc_box.set_anchors_preset(Control.PRESET_RIGHT_WIDE); proc_box.position = Vector2(-330, 200); proc_box.size = Vector2(310, 470)
	var sty := StyleBoxFlat.new(); sty.bg_color = Color(0.03, 0.06, 0.1, 0.72); sty.border_color = Color(1, 1, 1, 0.15); sty.set_border_width_all(1); sty.set_corner_radius_all(4); sty.content_margin_left = 12; sty.content_margin_right = 12; sty.content_margin_top = 10; sty.content_margin_bottom = 10
	proc_box.add_theme_stylebox_override("panel", sty); root.add_child(proc_box)
	var pv := VBoxContainer.new(); proc_box.add_child(pv)
	var hb := HBoxContainer.new(); pv.add_child(hb)
	var pb := _btn(hb, "‹", func(): button.emit("prev")); pb.custom_minimum_size = Vector2(34, 30)
	proc_title = _label(hb, "", 17, Color(1, 1, 1)); proc_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL; proc_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var nb := _btn(hb, "›", func(): button.emit("next")); nb.custom_minimum_size = Vector2(34, 30)
	proc_list = RichTextLabel.new(); proc_list.bbcode_enabled = true; proc_list.fit_content = false; proc_list.custom_minimum_size = Vector2(280, 270); proc_list.scroll_active = true
	proc_list.add_theme_font_size_override("normal_font_size", 15); pv.add_child(proc_list)
	var gb := HBoxContainer.new(); pv.add_child(gb)
	btn_guide = _btn(gb, "开始指导", func(): button.emit("guide")); btn_guide.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_crew = _btn(gb, "队友执行", func(): button.emit("crew")); btn_crew.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cw_list = RichTextLabel.new(); cw_list.bbcode_enabled = true; cw_list.custom_minimum_size = Vector2(280, 90); cw_list.add_theme_font_size_override("normal_font_size", 14); pv.add_child(cw_list)
	# touch / action buttons (bottom-right)
	touch_row = HBoxContainer.new(); touch_row.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT); touch_row.position = Vector2(-560, -70); touch_row.size = Vector2(540, 56); root.add_child(touch_row)
	touch_row.alignment = BoxContainer.ALIGNMENT_END
	go_btn = _btn(touch_row, "回复 GO", func(): button.emit("go")); go_btn.visible = false
	_btn(touch_row, "程序手册", func(): button.emit("book"))
	_btn(touch_row, "缩放", func(): button.emit("zoom"))
	_btn(touch_row, "外部视角", func(): button.emit("view"))
	_btn(touch_row, "跳过等待", func(): button.emit("skip"))

func _label(parent: Node, t: String, size: int, col: Color) -> Label:
	var l := Label.new(); l.text = t; l.add_theme_font_size_override("font_size", size); l.add_theme_color_override("font_color", col); l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l); return l

func _shadow(l: Label) -> void:
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85)); l.add_theme_constant_override("shadow_offset_x", 1); l.add_theme_constant_override("shadow_offset_y", 2)

func _btn(parent: Node, t: String, cb: Callable) -> Button:
	var b := Button.new(); b.text = t; b.add_theme_font_size_override("font_size", 17); b.custom_minimum_size = Vector2(96, 48); b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb); parent.add_child(b); return b

func say(who: String, text: String, dur: float) -> void:
	sub_who.text = who; sub_txt.text = text; _sub_until = _t + dur

func _process(dt: float) -> void:
	_t += dt
	if _t > _sub_until: sub_who.text = ""; sub_txt.text = ""

static func fmt_t(T: float) -> String:
	var a := absf(T); var m := int(a / 60.0); var s := int(a) % 60; var h := m / 60; m = m % 60
	var sign := "T−" if T < 0.0 else "T+"
	if h > 0: return "%s%d:%02d:%02d" % [sign, h, m, s]
	return "%s%02d:%02d" % [sign, m, s]

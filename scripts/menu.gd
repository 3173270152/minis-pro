## Start menu: vehicle, mode, disaster, options.
class_name Menu
extends CanvasLayer

signal start(cfg: Dictionary)

const ROCKETS := [
	["qihang", "启航号", "长征二号F级 · 四助推器 · 神舟式返回舱"],
	["cz2f", "长征二号F / 神舟", "中国载人航天主力 · 三人乘组"],
	["saturn", "土星五号 / 阿波罗", "110 米 · 五台 F-1 发动机"],
	["fh", "猎鹰重型 / 龙飞船", "三芯级 · 侧助推器返回着陆"],
	["shuttle", "航天飞机", "轨道器 + 外挂燃料箱 · 跑道着陆"]]
const DIS := [["off", "关闭"], ["random", "随机（轻/中/重）"], ["minor", "随机 · 轻微"], ["moderate", "随机 · 中等"], ["severe", "随机 · 严重"],
	["hold", "指定 · 计数暂停"], ["commLoss", "指定 · 通信中断"], ["cabinAlarm", "指定 · 舱内告警"], ["engineOut", "指定 · 一台发动机关机"],
	["padAbort", "指定 · 点火后中止"], ["padExplosion", "指定 · 发射台爆炸"], ["maxqBreakup", "指定 · 最大动压解体"], ["lesFail", "指定 · 逃逸失效"],
	["chuteFail", "指定 · 主伞故障"], ["retroFail", "指定 · 反推失效"]]

var cfg := {"rocket": "qihang", "mode": "astronaut", "dis": "off", "skip_walk": false, "play": "full", "q": "balanced"}
var cards := {}

func _ready() -> void:
	layer = 40
	var bg := TextureRect.new(); bg.set_anchors_preset(Control.PRESET_FULL_RECT); bg.texture = _bg_tex(); bg.stretch_mode = TextureRect.STRETCH_SCALE; add_child(bg)
	var dim := ColorRect.new(); dim.color = Color(0, 0.02, 0.05, 0.55); dim.set_anchors_preset(Control.PRESET_FULL_RECT); add_child(dim)
	var sc := ScrollContainer.new(); sc.set_anchors_preset(Control.PRESET_FULL_RECT); sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED; add_child(sc)
	var mc := MarginContainer.new(); mc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for k in ["left", "right"]: mc.add_theme_constant_override("margin_" + k, 60)
	mc.add_theme_constant_override("margin_top", 30); mc.add_theme_constant_override("margin_bottom", 30); sc.add_child(mc)
	var v := VBoxContainer.new(); v.add_theme_constant_override("separation", 14); mc.add_child(v)
	_l(v, "启 航", 64, Color(1, 1, 1)); _l(v, "第一人称载人航天 · 从航站楼到太空再回到地球", 20, Color(0.75, 0.85, 1.0))
	_l(v, "运载火箭", 18, Color(1.0, 0.75, 0.35))
	var g := GridContainer.new(); g.columns = 5; g.add_theme_constant_override("h_separation", 10); v.add_child(g)
	for r in ROCKETS:
		var b := Button.new(); b.toggle_mode = true; b.text = "%s\n%s" % [r[1], r[2]]; b.custom_minimum_size = Vector2(210, 84); b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 15); b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.pressed.connect(func(): _pick(r[0])); g.add_child(b); cards[r[0]] = b
	_pick("qihang")
	_l(v, "模式", 18, Color(1.0, 0.75, 0.35))
	var mh := HBoxContainer.new(); mh.add_theme_constant_override("separation", 10); v.add_child(mh)
	var ma := _b(mh, "宇航员 · 第一人称亲历全程"); var ms := _b(mh, "观众 · 观礼台看发射")
	ma.toggle_mode = true; ms.toggle_mode = true; ma.button_pressed = true
	ma.pressed.connect(func(): cfg.mode = "astronaut"; ma.button_pressed = true; ms.button_pressed = false)
	ms.pressed.connect(func(): cfg.mode = "spectator"; ms.button_pressed = true; ma.button_pressed = false)
	_l(v, "灾难", 18, Color(1.0, 0.75, 0.35))
	var ob := OptionButton.new(); ob.add_theme_font_size_override("font_size", 17); ob.custom_minimum_size = Vector2(360, 46)
	for d in DIS: ob.add_item(d[1])
	ob.item_selected.connect(func(i): cfg.dis = DIS[i][0]); v.add_child(ob)
	_l(v, "选择「指定」的灾难必然发生；随机灾难按严重程度抽取。逃生、开伞、反推是否成功，取决于你有没有正确设置相应的开关。", 14, Color(0.7, 0.75, 0.8))
	_l(v, "画质", 18, Color(1.0, 0.75, 0.35))
	var qh := HBoxContainer.new(); qh.add_theme_constant_override("separation", 10); v.add_child(qh)
	var qs := [["fast", "流畅 · 120 帧"], ["balanced", "均衡"], ["quality", "画质优先"]]
	var qb := []
	for q in qs:
		var b := _b(qh, q[1]); b.toggle_mode = true; b.button_pressed = q[0] == "balanced"; qb.append(b)
		b.pressed.connect(func(): cfg.q = q[0]; for i in qb.size(): qb[i].button_pressed = qs[i][0] == q[0])
	var cb := CheckBox.new(); cb.text = "跳过走路环节，直接坐进座舱"; cb.add_theme_font_size_override("font_size", 17); cb.toggled.connect(func(on): cfg.skip_walk = on); v.add_child(cb)
	var go := Button.new(); go.text = "开始任务"; go.custom_minimum_size = Vector2(320, 64); go.add_theme_font_size_override("font_size", 26); go.focus_mode = Control.FOCUS_NONE
	go.pressed.connect(func(): start.emit(cfg.duplicate()); queue_free()); v.add_child(go)
	_l(v, "操作：拖动屏幕环视 · 双指捏合/滚轮缩放 · 点击开关 · 左下摇杆走路（手机）/ WASD（电脑）", 14, Color(0.7, 0.75, 0.8))

func _pick(k: String) -> void:
	cfg.rocket = k
	for c in cards: cards[c].button_pressed = c == k

func _l(p: Node, t: String, s: int, c: Color) -> Label:
	var l := Label.new(); l.text = t; l.add_theme_font_size_override("font_size", s); l.add_theme_color_override("font_color", c); l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p.add_child(l); return l

func _b(p: Node, t: String) -> Button:
	var b := Button.new(); b.text = t; b.custom_minimum_size = Vector2(300, 52); b.add_theme_font_size_override("font_size", 17); b.focus_mode = Control.FOCUS_NONE; p.add_child(b); return b

func _bg_tex() -> Texture2D:
	return load("res://icon.png")

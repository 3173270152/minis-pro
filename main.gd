extends Node3D
## Entry point: builds the launch site and hands control to the game state machine.
var world: World
var pad: Pad
var rocket: Rocket
var cam: Camera3D
var capsule: Capsule
var console: Console
var frames := 0
var shot := ""
var view := "pad"

const VIEWS := {
	"pad": [Vector3(48, 10, 95), Vector3(-4, 34, 0)],
	"wide": [Vector3(260, 30, 330), Vector3(0, 40, 0)],
	"base": [Vector3(14, 4.0, 18), Vector3(0, 12, 0)],
	"engines": [Vector3(5.5, 6.2, 7.0), Vector3(0, 6.5, 0)],
	"top": [Vector3(9, 62, 13), Vector3(0, 59, 0)],
	"arm": [Vector3(4, 58, 10), Vector3(-6, 55, 0)],
	"capx": [Vector3(5, 58, 5), Vector3(0, 56.5, 0)],
	"tower": [Vector3(30, 50, -30), Vector3(-13, 45, 0)],
}

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="): shot = a.substr(7)
		if a.begins_with("--view="): view = a.substr(7)
		if a.begins_with("--sun="):
			pass
	world = World.new(); add_child(world)
	pad = Pad.new(); add_child(pad)
	rocket = Rocket.new(); rocket.position = Vector3(0, Pad.DECK, 0); add_child(rocket)
	capsule = Capsule.new(); capsule.position.y = Rocket.Y_CAPSULE; rocket.add_child(capsule)
	console = Console.new("qihang"); add_child(console)
	var L: Array = console.panel_list(); var sf: Array = capsule.surfaces()
	console.flow([sf[0]], ["abt", "cw", "dok", "avi", "com", "prp", "lts", "seq"].map(func(k): return console.find_panel(L, k)))
	console.flow([sf[1]], ["eps", "cba", "cbc"].map(func(k): return console.find_panel(L, k)))
	console.flow([sf[2]], ["ecs", "cbb"].map(func(k): return console.find_panel(L, k)))
	for a in OS.get_cmdline_user_args():
		if a == "--powered": console.auto_upto("seq")
	cam = Camera3D.new(); cam.fov = 55; cam.near = 0.05; cam.far = 200000.0; add_child(cam)
	if view.begins_with("cabin"):
		cam.fov = 78; cam.near = 0.02
		await get_tree().process_frame
		cam.global_transform = capsule.seat_anchor.global_transform
		var parts := view.split(":")
		if parts.size() > 2: cam.rotate_object_local(Vector3.UP, float(parts[1])); cam.rotate_object_local(Vector3.RIGHT, float(parts[2]))
		return
	if view == "capx": rocket.fairing.visible = false; rocket.les.visible = false
	var v: Array = VIEWS.get(view, VIEWS["pad"])
	cam.position = v[0]; cam.look_at(v[1])

func _process(_d: float) -> void:
	frames += 1
	if shot != "" and frames == 60:
		get_viewport().get_texture().get_image().save_png(shot); get_tree().quit()

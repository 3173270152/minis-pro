## Offline baker: run `godot --headless --script res://scripts/bake.gd` to pre-generate heavy procedural meshes.
extends SceneTree
func _init() -> void:
	var w := World.new()
	w.noise.seed = 4; w.noise.frequency = 0.0009; w.noise.fractal_octaves = 5
	w.ridge.seed = 9; w.ridge.frequency = 0.00011; w.ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED; w.ridge.fractal_octaves = 4; w.ridge.fractal_gain = 0.42
	var t0 := Time.get_ticks_msec()
	var mesh := w.make_terrain_mesh()
	print("terrain built in ", Time.get_ticks_msec() - t0, " ms, verts ", mesh.surface_get_array_len(0))
	print(ResourceSaver.save(mesh, "res://gen/terrain.res", ResourceSaver.FLAG_COMPRESS))
	w.free()
	quit()

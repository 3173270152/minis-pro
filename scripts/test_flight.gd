extends SceneTree
func _init() -> void:
	var f := Flight.new("shuttle"); var t := 0.0; var nxt := 0.0
	while t < 700.0:
		f.step(0.05); t += 0.05
		for e in f.events: print("  ev %s t=%.0f h=%.1fkm v=%d" % [e, t, f.alt() / 1000.0, int(f.v.length())])
		if t >= nxt: nxt += 60.0; print("t=%3.0f h=%6.1fkm v=%5d q=%5.1fkPa g=%.2f pitch=%4.1f ph=%d" % [t, f.state.alt / 1000.0, int(f.state.speed), f.state.q / 1000.0, f.state.g, f.state.pitch, f.phase])
		if f.phase == 4 and f.events.is_empty() and t > nxt - 59.0: break
	print("orbit apo %.0f km peri %.0f km" % [f.state.apo / 1000.0, f.state.peri / 1000.0])
	quit()

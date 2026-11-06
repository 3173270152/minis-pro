// hypergolic (N2O4/UDMH) exhaust: orange-red core with shock diamonds at sea level, widening and fading to a translucent
// bell-shaped plume in near vacuum ("thin" 0..1)
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float thin = 0.0;
uniform float flicker = 0.0;
varying vec3 vn;
varying vec3 vp;
void vertex(){ vn = NORMAL; vp = VERTEX; }
void fragment(){
	float y = UV.y;                                  // 0 at the nozzle, 1 at the tail
	float edge = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float core = pow(edge, mix(2.5, 1.2, thin));
	float diamonds = (1.0 - thin) * (0.5 + 0.5 * sin(y * 38.0 - TIME * 3.0)) * smoothstep(0.55, 0.0, y);
	float n = fract(sin(dot(floor(vec2(TIME * 30.0, y * 20.0)), vec2(12.9, 78.2))) * 43758.5);
	vec3 hot = vec3(1.0, 0.82, 0.55), mid = vec3(1.0, 0.45, 0.12), cool = vec3(0.55, 0.18, 0.05);
	vec3 c = mix(hot, mid, smoothstep(0.0, 0.35, y));
	c = mix(c, cool, smoothstep(0.35, 1.0, y));
	c = mix(c, vec3(0.6, 0.65, 1.0), thin * 0.35);
	float a = core * (1.0 - smoothstep(0.2, 1.0, y)) * (0.85 + 0.15 * n) * mix(1.0, 0.35, thin) + diamonds * 0.6 * core;
	ALBEDO = c * a * 5.0;
}

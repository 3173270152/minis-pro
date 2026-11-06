// layered exhaust plume (cylinder mesh, UV.y 0 at the nozzle -> 1 at the tail).
// layer 0 = hot core with Mach diamonds, 1 = outer turbulent flame. "thin" 0..1 = ambient pressure falling (plume balloons).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float thin = 0.0;
uniform float layer = 0.0;
uniform float power = 1.0;
uniform vec3 hot : source_color = vec3(1.0, 0.85, 0.6);
uniform vec3 mid : source_color = vec3(1.0, 0.45, 0.12);
uniform vec3 tail : source_color = vec3(0.5, 0.16, 0.05);
uniform float diamonds = 1.0;
float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n2(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), f.x), mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), f.x), f.y); }
void fragment(){
	float y = UV.y;
	float edge = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float turb = n2(vec2(UV.x * 9.0, y * 7.0 - TIME * 14.0)) * 0.6 + n2(vec2(UV.x * 23.0, y * 19.0 - TIME * 31.0)) * 0.4;
	vec3 c = mix(hot, mid, smoothstep(0.0, 0.3, y)); c = mix(c, tail, smoothstep(0.3, 1.0, y));
	float a;
	if (layer < 0.5) {
		float dm = diamonds * (1.0 - thin) * pow(0.5 + 0.5 * cos(y * 46.0), 6.0) * smoothstep(0.6, 0.0, y);
		a = pow(edge, 2.2) * (1.0 - smoothstep(0.05, 0.55, y)) * 1.6 + dm * pow(edge, 1.5) * 1.4;
		c = mix(c, vec3(1.0, 0.95, 0.85), 0.5);
	} else {
		a = pow(edge, mix(1.4, 0.8, thin)) * (1.0 - smoothstep(0.15, 1.0, y)) * (0.45 + 0.55 * turb) * mix(0.9, 0.35, thin);
	}
	ALBEDO = c * a * power * 3.0;
}

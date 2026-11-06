// dynamic exhaust plume (cylinder mesh, UV.y 0 at nozzle -> 1 at tail).
// layer 0 = white-hot core with Mach diamonds, 1 = outer turbulent flame. thin 0..1 = ambient pressure falling.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;
uniform float thin = 0.0;
uniform float layer = 0.0;
uniform float power = 1.0;
uniform float seed = 0.0;
uniform vec3 hot : source_color = vec3(1.0, 0.85, 0.6);
uniform vec3 mid : source_color = vec3(1.0, 0.45, 0.12);
uniform vec3 tail : source_color = vec3(0.5, 0.16, 0.05);
uniform float diamonds = 1.0;
varying float vy;
float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n2(vec2 p){ vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), f.x), mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), f.x), f.y); }
float fbm(vec2 p){ float a = 0.0, w = 0.5; for (int i = 0; i < 4; i++) { a += w * n2(p); p = p * 2.03 + 7.1; w *= 0.5; } return a; }
void vertex(){
	float y = clamp(0.5 - VERTEX.y, 0.0, 1.0); vy = y;
	// teardrop profile: narrow at the nozzle, swells, then tapers to a point (no flat end)
	vec2 rr = normalize(VERTEX.xz + vec2(1e-5));
	float prof = layer < 0.5 ? (0.55 + 0.25 * y) * (1.0 - smoothstep(0.35, 1.0, y) * 0.92)
		: (0.5 + 0.6 * smoothstep(0.0, 0.3, y)) * (1.0 - smoothstep(0.4, 1.0, y) * 0.9);
	VERTEX.xz = rr * prof;
	float t = TIME + seed * 13.0;
	// flutter: radius breathes and the column snakes, more toward the tail
	float k = smoothstep(0.05, 1.0, y) * (layer > 0.5 ? 1.0 : 0.35);
	float r = 1.0 + k * (0.35 * (fbm(vec2(UV.x * 6.0, y * 4.0 - t * 9.0)) - 0.5) + 0.12 * sin(t * 37.0 + y * 20.0));
	VERTEX.xz *= r;
	VERTEX.x += k * 0.18 * sin(t * 5.3 + y * 6.0 + seed);
	VERTEX.z += k * 0.18 * cos(t * 4.1 + y * 5.0 + seed * 2.0);
}
void fragment(){
	float y = vy;
	float t = TIME + seed * 13.0;
	float edge = abs(dot(normalize(NORMAL), normalize(VIEW)));
	// stretched flame tongues streaming downward
	float f1 = fbm(vec2(UV.x * 10.0 + seed, y * 5.0 - t * 16.0));
	float f2 = fbm(vec2(UV.x * 26.0 - seed, y * 14.0 - t * 34.0));
	float turb = f1 * 0.65 + f2 * 0.35;
	vec3 c = mix(hot, mid, smoothstep(0.0, 0.28, y)); c = mix(c, tail, smoothstep(0.3, 0.95, y));
	float a;
	if (layer < 0.5) {
		// shock diamonds: bright discs that sit still while the gas streams through
		float ph = y * 44.0;
		float dm = diamonds * (1.0 - thin) * pow(0.5 + 0.5 * cos(ph), 8.0) * smoothstep(0.55, 0.02, y);
		float body = (1.0 - smoothstep(0.02, 0.5, y + (turb - 0.5) * 0.12));
		a = pow(edge, 2.0) * body * 1.8 + dm * pow(edge, 1.2) * 2.2;
		c = mix(c, vec3(1.0, 0.95, 0.82), 0.35 * (1.0 - y));
	} else {
		// ragged tail: noise eats the end of the flame instead of a smooth fade
		float cut = smoothstep(0.0, 0.25, (1.0 - y) * 1.15 - (1.0 - turb) * 0.55);
		float lick = smoothstep(0.35, 0.75, turb);
		a = pow(edge, mix(0.9, 0.6, thin)) * cut * (0.25 + 1.1 * lick) * mix(1.0, 0.4, thin);
		c *= 0.75 + 0.6 * lick; c = mix(c, c * vec3(1.0, 0.7, 0.4), 0.5);
	}
	float flick = 0.9 + 0.1 * sin(t * 61.0) * sin(t * 23.0 + 1.0);
	ALBEDO = c * a * power * flick * (layer < 0.5 ? 1.5 : 1.1);
}

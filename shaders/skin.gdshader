// rocket skin: painted aluminium with weld rings, stringer seams, access panels, grime and optional LOX frost
shader_type spatial;
render_mode cull_disabled;
uniform vec4 base : source_color = vec4(0.92, 0.92, 0.89, 1.0);
uniform float ring_m = 2.4;        // metres between circumferential welds
uniform float seams = 24.0;        // longitudinal seams around the circumference
uniform float rough = 0.42;
uniform float grime = 0.25;
uniform float frost = 0.0;         // 0..1 white ice coat over cryogenic tanks
uniform float soot = 0.0;          // darkening towards the bottom (v near 0)
uniform float panel_m = 0.9;       // size of small access panels
uniform sampler2D nz : hint_default_white, filter_linear_mipmap, repeat_enable;
float aline(float f, float w){ float d = abs(fract(f + 0.5) - 0.5); float fw = fwidth(f) * 1.2; return 1.0 - smoothstep(w, w + fw, d); }
void fragment(){
	vec2 uv = UV;
	float ring = aline(uv.y / ring_m, 0.004);
	float seam = aline(uv.x * seams, 0.006);
	// sparse rectangular access panels
	vec2 pc = vec2(uv.x * seams * 2.0, uv.y / panel_m);
	vec2 cell = floor(pc); float h = fract(sin(dot(cell, vec2(12.9898, 78.233))) * 43758.5453);
	vec2 f = fract(pc);
	float panel = (h > 0.9) ? max(aline(f.x, 0.05) * step(0.1, f.y) * step(f.y, 0.9), aline(f.y, 0.05) * step(0.1, f.x) * step(f.x, 0.9)) : 0.0;
	panel *= step(0.15, f.x) * step(f.x, 0.85) * step(0.15, f.y) * step(f.y, 0.85) + (h > 0.9 ? 0.0 : 0.0);
	float n1 = texture(nz, uv * vec2(6.0, 0.25)).r;
	float n2 = texture(nz, uv * vec2(23.0, 1.3)).r;
	vec3 c = base.rgb * (1.0 - grime * 0.25 * (n1 - 0.5) - grime * 0.12 * n2);
	c *= 1.0 - 0.35 * max(ring, max(seam * 0.6, panel * 0.5));
	c = mix(c, c * 0.35, soot * (1.0 - smoothstep(0.0, 6.0, uv.y)) * (0.6 + 0.4 * n1));
	float r = rough + 0.12 * (n2 - 0.5) + 0.15 * ring;
	vec3 fro = vec3(0.93, 0.95, 0.97) * (0.9 + 0.1 * n2);
	float fz = frost * smoothstep(0.35, 0.55, n1 * 0.6 + 0.5);
	ALBEDO = mix(c, fro, fz);
	ROUGHNESS = mix(r, 0.9, fz);
	METALLIC = 0.0;
	// seams as shallow grooves in the normal
	NORMAL_MAP = normalize(vec3(0.5 + (n2 - 0.5) * (0.06 + fz * 0.5), 0.5 + (ring * 0.0) - 0.0, 1.0)) * 0.5 + 0.25;
	NORMAL_MAP_DEPTH = 0.6 + fz * 2.0;
}

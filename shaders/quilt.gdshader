// cabin wall lining: quilted beige fabric panels with stitching, velcro patches and soft folds
shader_type spatial;
render_mode cull_disabled;
uniform vec4 base : source_color = vec4(0.86, 0.80, 0.66, 1.0);
uniform vec2 cells = vec2(44.0, 7.0);   // quilt cells around (per full turn) and per metre
uniform sampler2D nz : hint_default_white, filter_linear_mipmap, repeat_enable;
float stitch(float f){ float d = abs(fract(f) - 0.5) * 2.0; return smoothstep(0.93, 0.99, d); }
void fragment(){
	vec2 q = vec2(UV.x * cells.x, UV.y * cells.y);
	vec2 f = fract(q) - 0.5;
	float puff = 1.0 - dot(f, f) * 2.6;                     // pillowed cells
	float st = max(stitch(q.x), stitch(q.y));
	float dash = step(0.5, fract((q.x + q.y) * 9.0));
	float n = texture(nz, UV * vec2(4.0, 1.5)).r;
	vec2 cell = floor(q); float h = fract(sin(dot(cell, vec2(91.7, 13.1))) * 4375.85);
	vec3 c = base.rgb * (0.86 + 0.16 * puff + 0.06 * (n - 0.5));
	c *= 1.0 - 0.28 * st * dash;
	if (h > 0.93) c = mix(c, vec3(0.62, 0.62, 0.6), 0.7 * step(abs(f.x), 0.22) * step(abs(f.y), 0.12));   // velcro patch
	ALBEDO = c;
	ROUGHNESS = 0.92;
	vec2 g = -f * 1.6 * (1.0 - st);
	NORMAL_MAP = normalize(vec3(g.x, g.y, 1.0)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
	SSS_STRENGTH = 0.0;
}

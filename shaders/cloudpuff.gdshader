// cumulus puff billboard: sun-lit top, blue-grey base, soft noisy edge, lit from inside by the rocket flame
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;
uniform sampler2D puff : filter_linear_mipmap;
uniform sampler2D nz : filter_linear_mipmap, repeat_enable;
uniform vec3 sun_dir = vec3(0.3, 0.8, 0.4);
uniform vec3 flame_pos = vec3(0.0, -1e7, 0.0);
uniform float flame_pow = 0.0;
uniform float day = 1.0;
varying vec3 wc;
varying float sz;
varying float shade;
void vertex(){
	wc = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	sz = length(MODEL_MATRIX[0].xyz);
	shade = INSTANCE_CUSTOM.r;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sz, INV_VIEW_MATRIX[1] * sz, INV_VIEW_MATRIX[2] * sz, vec4(wc, 1.0));
}
void fragment(){
	vec2 q = UV * 2.0 - 1.0;
	float n = texture(nz, UV * 0.7 + wc.xz * 0.0003 + TIME * 0.002).r;
	float a = texture(puff, UV).a * smoothstep(0.15, 0.6, n + 0.35 - length(q) * 0.25);
	// near-camera fade so a puff never fills the screen as a flat card
	float d = length(wc - CAMERA_POSITION_WORLD);
	a *= smoothstep(sz * 0.15, sz * 0.6, d);
	float top = clamp(0.5 - q.y * 0.5, 0.0, 1.0);     // UV.y 0 = top of the card
	float lit = clamp(0.35 + 0.65 * top * (0.6 + 0.4 * max(dot(normalize(sun_dir), vec3(0, 1, 0)), 0.0)) + 0.25 * (n - 0.5), 0.0, 1.0);
	vec3 c = mix(vec3(0.52, 0.56, 0.64), vec3(1.0, 0.99, 0.96), lit) * mix(0.25, 1.0, day) * (0.8 + 0.2 * shade);
	// flame glow scattering through the cloud
	float fd = length(wc - flame_pos);
	c += vec3(1.0, 0.55, 0.2) * flame_pow * 2.2 * exp(-fd / (sz * 1.6));
	ALBEDO = c;
	ALPHA = clamp(a * 0.85, 0.0, 1.0);
}

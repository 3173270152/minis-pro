shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;
uniform sampler2D clouds : filter_linear_mipmap;
uniform vec3 sun_dir = vec3(0.3, 0.6, 0.7);
uniform float fade = 1.0;
uniform float u_off = 0.0;
uniform float drift = 0.0;
varying vec3 wn;
void vertex(){ wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz); }
void fragment(){
	float a = texture(clouds, vec2(fract(UV.x + u_off + drift), UV.y)).r;
	float ndl = dot(normalize(wn), normalize(sun_dir));
	float lit = smoothstep(-0.1, 0.3, ndl);
	vec3 warm = mix(vec3(1.0, 0.6, 0.4), vec3(1.0), smoothstep(0.0, 0.3, ndl));
	ALBEDO = vec3(1.0) * warm * (0.08 + 1.1 * lit);
	ALPHA = clamp(a * 1.15, 0.0, 1.0) * fade;
}

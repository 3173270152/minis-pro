// atmospheric limb: glow strongest where the view grazes the shell, blue on the day side, orange at the terminator
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back;
uniform vec3 sun_dir = vec3(0.3, 0.6, 0.7);
uniform float fade = 1.0;
uniform float planet_r = 6371000.0;
uniform float atmo_r = 6471000.0;
varying vec3 wn;
varying vec3 wpos;
void vertex(){ wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz); wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment(){
	vec3 n = normalize(wn); vec3 V = normalize(CAMERA_POSITION_WORLD - wpos);
	float rim = 1.0 - clamp(dot(n, V), 0.0, 1.0);
	float ndl = dot(n, normalize(sun_dir));
	float day = smoothstep(-0.25, 0.35, ndl);
	vec3 col = mix(vec3(1.0, 0.42, 0.15), vec3(0.32, 0.55, 1.0), smoothstep(-0.05, 0.4, ndl));
	float g = pow(rim, 4.0) * 1.8 + pow(rim, 12.0) * 2.5;
	ALBEDO = col * g * day;
	ALPHA = fade;
}

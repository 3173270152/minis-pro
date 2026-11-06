// Earth surface: Blue Marble albedo, ocean sun glint from the water mask, city lights on the night side,
// warm terminator, aerial haze toward the limb. Self-lit (the scene sun is far too weak a model at planetary scale).
shader_type spatial;
render_mode unshaded, depth_draw_opaque, cull_back;
uniform sampler2D day : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D night : source_color, filter_linear_mipmap;
uniform sampler2D water : filter_linear_mipmap;
uniform sampler2D nrm : hint_normal, filter_linear_mipmap;
uniform vec3 sun_dir = vec3(0.3, 0.6, 0.7);
uniform float fade = 1.0;
uniform float u_off = 0.0;
varying vec3 wn;
varying vec3 wpos;
void vertex(){ wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz); wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment(){
	vec2 uv = vec2(fract(UV.x + u_off), UV.y);
	vec3 alb = texture(day, uv).rgb;
	float w = texture(water, uv).r;
	vec3 n = normalize(wn);
	vec3 L = normalize(sun_dir);
	vec3 V = normalize(CAMERA_POSITION_WORLD - wpos);
	float ndl = dot(n, L);
	float lit = smoothstep(-0.08, 0.25, ndl);
	// ocean: darker, bluer, specular glint
	vec3 ocean = alb * vec3(0.55, 0.75, 1.0) * 0.8;
	vec3 base = mix(alb * 1.08, ocean, w);
	vec3 H = normalize(L + V);
	float spec = pow(max(dot(n, H), 0.0), 180.0) * w * 2.6 + pow(max(dot(n, H), 0.0), 18.0) * w * 0.12;
	vec3 warm = mix(vec3(1.0, 0.55, 0.32), vec3(1.0), smoothstep(0.0, 0.35, ndl));
	vec3 c = base * lit * warm * 1.25 + vec3(1.0, 0.92, 0.8) * spec * lit;
	vec3 city = texture(night, uv).rgb * vec3(1.0, 0.82, 0.55) * 2.2;
	c += city * (1.0 - smoothstep(-0.12, 0.05, ndl));
	// haze toward the limb (thicker air along grazing view)
	float graze = 1.0 - clamp(dot(n, V), 0.0, 1.0);
	c = mix(c, vec3(0.45, 0.62, 0.95) * lit, pow(graze, 3.0) * 0.55);
	ALBEDO = c;
	ALPHA = fade;
}

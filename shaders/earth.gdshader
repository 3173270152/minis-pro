// Earth surface: Blue Marble albedo, ocean sun glint from the water mask, city lights on the night side,
// warm terminator, aerial haze toward the limb. Self-lit (the scene sun is far too weak a model at planetary scale).
shader_type spatial;
render_mode unshaded, depth_draw_opaque, cull_disabled;
uniform sampler2D day : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D night : source_color, filter_linear_mipmap;
uniform sampler2D water : filter_linear_mipmap;
uniform sampler2D nrm : hint_normal, filter_linear_mipmap;
uniform vec3 sun_dir = vec3(0.3, 0.6, 0.7);
uniform float fade = 1.0;
uniform float kscale = 1.0;
uniform float u_off = 0.0;
// the proxy mesh is only a bounding shell: every pixel ray-casts the exact sphere (no facets, no z-fighting)
uniform vec3 centre_rel = vec3(0.0, -6371000.0, 0.0);   // sphere centre minus camera, true metres
uniform float cam_alt = 100.0;                           // camera height above the analytic sphere
uniform float r_eff = 6370980.0;
uniform mat3 inv_b = mat3(1.0);
varying vec3 wpos;
void vertex(){ wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment(){
	vec3 dir = normalize(wpos - CAMERA_POSITION_WORLD);
	vec3 oc = -centre_rel;
	float b = dot(oc, dir);
	float cc = cam_alt * (2.0 * r_eff + cam_alt);
	float disc = b * b - cc;
	if (disc < 0.0 || b > 0.0) discard;
	float t = cc / (-b + sqrt(disc));
	vec3 hit = CAMERA_POSITION_WORLD + dir * t;
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(hit, 1.0);
	DEPTH = clamp(clip.z / clip.w, 1e-7, 1.0);
	vec3 wn = normalize(oc + dir * t);
	vec3 l = inv_b * wn;
	float u = atan(l.x, l.z) / 6.2831853; u = u < 0.0 ? u + 1.0 : u;
	vec2 uv = vec2(fract(u + u_off), acos(clamp(l.y, -1.0, 1.0)) / 3.1415927);
	vec2 uv2 = vec2(fract(u + 0.5), uv.y);
	vec2 dx = dFdx(uv), dy = dFdy(uv), dx2 = dFdx(uv2), dy2 = dFdy(uv2);
	if (abs(dx2.x) + abs(dy2.x) < abs(dx.x) + abs(dy.x)) { dx = dx2; dy = dy2; }
	vec3 V = -dir;
	vec3 alb = textureGrad(day, uv, dx, dy).rgb;
	float w = textureGrad(water, uv, dx, dy).r;
	vec3 n = normalize(wn);
	vec3 L = normalize(sun_dir);
	float ndl = dot(n, L);
	float lit = smoothstep(-0.08, 0.25, ndl);
	// ocean: darker, bluer, specular glint
	vec3 ocean = alb * vec3(0.55, 0.75, 1.0) * 0.8;
	vec3 base = mix(alb * 1.08, ocean, w);
	vec3 H = normalize(L + V);
	float spec = pow(max(dot(n, H), 0.0), 180.0) * w * 2.6 + pow(max(dot(n, H), 0.0), 18.0) * w * 0.12;
	vec3 warm = mix(vec3(1.0, 0.55, 0.32), vec3(1.0), smoothstep(0.0, 0.35, ndl));
	vec3 c = base * lit * warm * 1.25 + vec3(1.0, 0.92, 0.8) * spec * lit;
	vec3 city = textureGrad(night, uv, dx, dy).rgb * vec3(1.0, 0.82, 0.55) * 2.2;
	c += city * (1.0 - smoothstep(-0.12, 0.05, ndl));
	// haze toward the limb (thicker air along grazing view)
	float graze = 1.0 - clamp(dot(n, V), 0.0, 1.0);
	c = mix(c, vec3(0.45, 0.62, 0.95) * lit, pow(graze, 3.0) * 0.35);
	ALBEDO = c * 0.45;
}

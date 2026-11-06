// Launch-site terrain on the curved Earth: photo-textured grass / grass-snow / snow / snowy rock,
// tinted and finally blended into the global Earth texture so the patch melts into the planet.
shader_type spatial;
uniform sampler2D nz : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nn : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D macro_col : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D macro_nrm : filter_linear_mipmap_anisotropic;
uniform sampler2D t_grass : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D t_gsnow : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D t_snow : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D t_srock : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D day : source_color, filter_linear_mipmap;
uniform mat3 inv_b = mat3(1.0);
uniform float earth_gain = 0.45;
varying vec3 wp;
varying vec3 lp;
const float RE = 6371000.0;
void vertex(){
	lp = VERTEX;
	VERTEX.y -= dot(VERTEX.xz, VERTEX.xz) / (2.0 * RE);
	wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
vec3 tx(sampler2D t, vec2 p, float dist){
	// two rotated scales + a coarse one far away: no visible tiling
	vec2 q = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p;
	vec3 a = texture(t, p / 7.0).rgb, b = texture(t, q / 29.0).rgb, c = texture(t, p / 230.0).rgb;
	return mix(mix(a, b, 0.4), c, smoothstep(150.0, 1500.0, dist));
}
void fragment(){
	float dist = length(wp - CAMERA_POSITION_WORLD);
	vec2 p = lp.xz;
	float n1 = texture(nz, p * 0.0009).r, n2 = texture(nz, p * 0.011).r, n3 = texture(nz, p * 0.09).r;
	float h = lp.y + (n2 - 0.5) * 120.0;
	float rock = clamp(COLOR.r + (n1 - 0.5) * 0.5, 0.0, 1.0);
	float snowline = 1650.0 + (n1 - 0.5) * 500.0;
	vec3 grass = tx(t_grass, p, dist);
	vec3 c = grass;
	c = mix(c, tx(t_gsnow, p, dist), smoothstep(snowline - 380.0, snowline - 120.0, h));
	c = mix(c, tx(t_snow, p, dist), smoothstep(snowline, snowline + 260.0, h));
	vec3 sr = tx(t_srock, p, dist);
	c = mix(c, mix(sr * vec3(0.75, 0.72, 0.7), sr, smoothstep(snowline - 600.0, snowline, h)), smoothstep(0.35, 0.75, rock));
	c *= 0.85 + 0.3 * n3;
	// global Earth colour under this spot (same mapping as the globe)
	vec3 dir = normalize(vec3(lp.x, RE + lp.y, lp.z));
	vec3 l = inv_b * dir;
	float u = atan(l.x, l.z) / 6.2831853; u = u < 0.0 ? u + 1.0 : u;
	vec3 ec = textureLod(day, vec2(u, acos(clamp(l.y, -1.0, 1.0)) / 3.1415927), 0.0).rgb * earth_gain;
	float el = dot(ec, vec3(0.333)) + 0.02;
	float snowy = smoothstep(snowline - 200.0, snowline + 200.0, h);
	c *= mix(vec3(1.0), clamp(ec / el, 0.6, 1.5), 0.35 * (1.0 - snowy));
	float r = max(abs(lp.x), abs(lp.z));
	float far = max(smoothstep(9000.0, 45000.0, dist), smoothstep(25000.0, 59000.0, r));
	c = mix(c, mix(ec, vec3(0.9, 0.92, 0.95), snowy * 0.8), far);
	vec2 muv = (lp.xz + 60000.0) / 120000.0;
	vec3 mn = texture(macro_nrm, muv).rgb * 2.0 - 1.0; mn = normalize(vec3(mn.x, mn.z, mn.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(mn, 0.0)).xyz);
	ALBEDO = c;
	ROUGHNESS = mix(0.95, 0.7, snowy);
	vec3 nA = texture(nn, p * 0.08).rgb, nB = texture(nn, p * 0.55).rgb;
	NORMAL_MAP = normalize(mix(nA, nB, 0.5 * (1.0 - smoothstep(20.0, 80.0, dist))) * 2.0 - 1.0) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = mix(1.0, 0.3, smoothstep(50.0, 600.0, dist));
}

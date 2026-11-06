// Gobi desert: gravel plain near the site, wind-rippled sand, dark rock on slopes, multi-scale detail without visible tiling
shader_type spatial;
uniform sampler2D nz : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D nn : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
varying vec3 wp;
varying float vdist;
void vertex(){ wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment(){
	float dist = length(wp - CAMERA_POSITION_WORLD);
	vec2 p = wp.xz;
	float n1 = texture(nz, p * 0.0009).r, n2 = texture(nz, p * 0.011).r, n3 = texture(nz, p * 0.09).r, n4 = texture(nz, p * 0.7).r;
	float rock = clamp(COLOR.r + (n1 - 0.5) * 0.6, 0.0, 1.0);
	vec3 sand = mix(vec3(0.66, 0.52, 0.36), vec3(0.56, 0.44, 0.30), n1) * (0.88 + 0.24 * n2);
	vec3 gravel = mix(vec3(0.46, 0.41, 0.35), vec3(0.58, 0.52, 0.44), n3) * (0.85 + 0.3 * n4);
	vec3 rockc = mix(vec3(0.20, 0.17, 0.15), vec3(0.34, 0.28, 0.23), n2) * (0.8 + 0.3 * n3);
	float gr = smoothstep(0.35, 0.7, n2 * 0.7 + n1 * 0.5 - 0.1) * (1.0 - smoothstep(0.9, 1.0, COLOR.b) * 0.3);
	vec3 c = mix(sand, gravel, gr);
	c = mix(c, rockc, rock);
	// snow on the high ridges
	c = mix(c, vec3(0.88, 0.9, 0.93), smoothstep(0.72, 0.86, COLOR.g + (n2 - 0.5) * 0.15) * smoothstep(0.3, 0.6, COLOR.r));
	// wind ripples in the sand (fade with distance to avoid shimmer)
	float rip = sin(p.x * 2.1 + p.y * 0.9 + n3 * 6.0) * 0.5 + 0.5;
	c *= 1.0 - 0.06 * rip * (1.0 - gr) * (1.0 - smoothstep(30.0, 120.0, dist));
	ALBEDO = c;
	ROUGHNESS = mix(0.92, 0.75, rock);
	vec3 nA = texture(nn, p * 0.08).rgb, nB = texture(nn, p * 0.55).rgb;
	NORMAL_MAP = normalize(mix(nA, nB, 0.5 * (1.0 - smoothstep(20.0, 80.0, dist))) * 2.0 - 1.0) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = mix(1.2, 0.4, smoothstep(50.0, 600.0, dist));
}

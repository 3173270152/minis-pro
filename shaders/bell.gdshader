// regeneratively cooled engine nozzle: coolant tubes, heat tint from throat (straw/blue) to exit (dark)
shader_type spatial;
render_mode cull_disabled;
uniform float tubes = 180.0;
uniform float len = 2.0;
uniform vec4 metal : source_color = vec4(0.42, 0.40, 0.38, 1.0);
uniform float glow = 0.0;
void fragment(){
	float t = clamp(UV.y / len, 0.0, 1.0);
	float tube = sin(UV.x * tubes * 6.2831) * 0.5 + 0.5;
	vec3 straw = vec3(0.55, 0.42, 0.25), blue = vec3(0.22, 0.25, 0.35), dark = vec3(0.12, 0.11, 0.11);
	vec3 tint = mix(mix(straw, blue, smoothstep(0.05, 0.35, t)), dark, smoothstep(0.45, 1.0, t));
	ALBEDO = mix(metal.rgb, tint, 0.65) * (0.82 + 0.18 * tube);
	METALLIC = 0.85; ROUGHNESS = 0.38 + 0.2 * t;
	NORMAL_MAP = vec3(0.5 + 0.35 * cos(UV.x * tubes * 6.2831), 0.5, 1.0);
	EMISSION = vec3(1.0, 0.45, 0.15) * glow * (1.0 - t) * 3.0;
	if (!FRONT_FACING) { ALBEDO *= 0.3; EMISSION *= 2.0; }
}

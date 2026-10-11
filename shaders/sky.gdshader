shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

// Camera-attached backdrop: warm glowing canopy light upper right, greener haze low.
uniform vec4 top_color : source_color = vec4(0.97, 0.92, 0.82, 1.0);
uniform vec4 glow_color : source_color = vec4(1.0, 0.95, 0.86, 1.0);
uniform vec4 low_color : source_color = vec4(0.86, 0.89, 0.74, 1.0);

void fragment() {
	vec3 color = mix(low_color.rgb, top_color.rgb, smoothstep(0.75, 0.35, UV.y));
	float glow = 1.0 - smoothstep(0.0, 0.75, distance(UV, vec2(0.8, 0.12)));
	ALBEDO = mix(color, glow_color.rgb, glow * 0.8);
}

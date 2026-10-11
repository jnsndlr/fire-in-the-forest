shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

// Soft additive light shaft. UV.x runs across the beam, UV.y along it.
uniform vec4 tint : source_color = vec4(1.0, 0.86, 0.80, 1.0);
uniform float strength = 0.16;

void fragment() {
	float across = pow(1.0 - abs(UV.x * 2.0 - 1.0), 1.6);
	float along = smoothstep(0.0, 0.35, UV.y) * smoothstep(1.0, 0.55, UV.y);
	float shimmer = 0.85 + 0.15 * sin(TIME * 0.35 + UV.y * 4.0);
	ALBEDO = tint.rgb * across * along * strength * shimmer;
}

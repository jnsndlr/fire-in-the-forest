shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

// Painted distant-scenery cards (tools/blender/sprites.py), drawn in bulk with
// MultiMesh. Instance colour tints each card; depth haze matches the pigment shader.
uniform sampler2D sprite : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 haze_low : source_color = vec4(0.88, 0.90, 0.76, 1.0);
uniform vec4 haze_high : source_color = vec4(0.97, 0.91, 0.84, 1.0);
uniform float haze_density = 0.05;

varying vec3 world_pos;
varying vec3 tint;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	tint = COLOR.rgb;
}

void fragment() {
	vec4 paint = texture(sprite, UV);
	float haze = 1.0 - exp(-clamp(-world_pos.z, 0.0, 120.0) * haze_density);
	vec3 haze_color = mix(haze_low.rgb, haze_high.rgb, smoothstep(-2.0, 28.0, world_pos.y));
	ALBEDO = mix(paint.rgb * tint, haze_color, haze);
	ALPHA = paint.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}

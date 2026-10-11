shader_type spatial;
render_mode cull_disabled, specular_disabled;

// Canopy leaf clumps built from flat leaf cards (after The Witness's trees):
// - normals are bent to point away from each clump's centre, so a clump shades
//   like one soft volume instead of a tangle of flat cards;
// - back faces render, and keep that outward normal instead of the flipped one;
// - cards fade out by eroding the leaf alpha as they turn edge-on to the camera;
// - interiors darken (vertex colour R: 0 at the clump centre, 1 at its surface) and shade turns cool.
uniform sampler2D leaves : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 paint_color : source_color = vec4(0.5, 0.58, 0.31, 1.0);
uniform vec4 light_color : source_color = vec4(0.70, 0.74, 0.45, 1.0);
uniform vec4 interior_color : source_color = vec4(0.22, 0.30, 0.26, 1.0);
uniform vec4 shade_tint : source_color = vec4(0.62, 0.74, 0.92, 1.0);
uniform float shade_strength = 0.22;
uniform float edge_fade_start = 0.08; // |facing| where cards are fully gone
uniform float edge_fade_end = 0.4;    // |facing| where cards are fully solid
uniform float sway = 0.04;
uniform vec4 haze_low : source_color = vec4(0.88, 0.90, 0.76, 1.0);
uniform vec4 haze_high : source_color = vec4(0.97, 0.91, 0.84, 1.0);
uniform float haze_density = 0.05;

varying vec3 world_pos;
varying vec3 world_normal;
varying float outer;

float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Gentle breeze: outer leaves drift more than the clump core.
	float t = TIME * 1.3 + wp.x * 0.35 + wp.y * 0.2;
	vec3 drift = vec3(sin(t), sin(t * 1.7 + 1.3) * 0.5, cos(t * 0.8)) * sway * COLOR.r;
	VERTEX += (inverse(MODEL_MATRIX) * vec4(drift, 0.0)).xyz;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	outer = COLOR.r;
}

void fragment() {
	// Godot flips NORMAL on back faces when culling is off; undo that so both sides
	// share the clump's outward normal.
	if (!FRONT_FACING) NORMAL = -NORMAL;
	// The card's true face normal (not the bent one) decides the edge fade.
	vec3 face = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	float facing = abs(dot(face, VIEW));
	float fade = smoothstep(edge_fade_start, edge_fade_end, facing);
	vec4 leaf = texture(leaves, UV);
	// Alpha is a distance field (0.5 at the leaf edge): lowering it erodes leaves.
	ALPHA = leaf.a - (1.0 - fade) * 0.5;
	ALPHA_SCISSOR_THRESHOLD = 0.5;

	float wash = noise(world_pos * 0.9) * 0.6 + noise(world_pos * 3.0) * 0.4;
	float top = smoothstep(0.15, 0.85, world_normal.y + (wash - 0.5) * 0.6);
	vec3 color = mix(paint_color.rgb, light_color.rgb, top * outer) * leaf.rgb * 1.12;
	color *= 1.0 + (wash - 0.5) * 0.25;
	color = mix(interior_color.rgb, color, mix(0.3, 1.0, smoothstep(0.0, 0.9, outer)));
	float haze = 1.0 - exp(-clamp(-world_pos.z, 0.0, 120.0) * haze_density);
	vec3 haze_color = mix(haze_low.rgb, haze_high.rgb, smoothstep(-2.0, 28.0, world_pos.y));
	ALBEDO = color * (1.0 - haze);
	EMISSION = haze_color * haze;
	ROUGHNESS = 1.0;
}

void light() {
	// Soft two-tone shading like the pigment shader; the shaded side picks up a
	// cool bluish cast instead of just going darker.
	float edge = noise(world_pos * 2.3) - 0.5;
	float lit = smoothstep(-0.2, 0.35, dot(NORMAL, LIGHT) + edge * 0.35);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * lit / PI;
	DIFFUSE_LIGHT += shade_tint.rgb * LIGHT_COLOR * (1.0 - lit * ATTENUATION) * shade_strength / PI;
}

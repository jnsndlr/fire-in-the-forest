shader_type spatial;
render_mode specular_disabled;

// Painterly surface: world-anchored pigment wash, soft-banded light, optional
// moss/highlight caps on upward faces, lumpy silhouettes, and depth haze that
// fades anything behind the play plane (z < 0) toward warm atmosphere.
uniform vec4 paint_color : source_color = vec4(0.5, 0.6, 0.3, 1.0);
uniform vec4 moss_color : source_color = vec4(0.62, 0.71, 0.40, 1.0);
uniform float moss = 0.0;
uniform float lump = 0.0;
uniform float rim = 0.0;
uniform vec3 grain_scale = vec3(1.0);
uniform float pigment_strength = 0.16;
uniform vec4 haze_low : source_color = vec4(0.88, 0.90, 0.76, 1.0);
uniform vec4 haze_high : source_color = vec4(0.97, 0.91, 0.84, 1.0);
uniform float haze_density = 0.05;

varying vec3 world_pos;
varying vec3 world_normal;

float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (lump > 0.0) {
		float n = noise(wp * 0.8) * 0.65 + noise(wp * 2.2) * 0.35;
		VERTEX += NORMAL * (n - 0.5) * lump;
		wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
	world_pos = wp;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 gp = world_pos * grain_scale;
	float wash = noise(gp * 1.7) * 0.6 + noise(gp * 6.0) * 0.4;
	vec3 color = paint_color.rgb * (1.0 + (wash - 0.5) * pigment_strength * 2.0);
	// Slow warm/cool drift like uneven watercolor pigment.
	color *= mix(vec3(1.0), vec3(1.07, 0.97, 0.94), noise(world_pos * 0.3));
	float cap = smoothstep(0.3, 0.7, world_normal.y + (wash - 0.5) * 0.8) * moss;
	color = mix(color, moss_color.rgb * (0.9 + wash * 0.2), cap);
	float depth = clamp(-world_pos.z, 0.0, 120.0);
	float haze = 1.0 - exp(-depth * haze_density);
	vec3 haze_color = mix(haze_low.rgb, haze_high.rgb, smoothstep(-2.0, 28.0, world_pos.y));
	ALBEDO = color * (1.0 - haze);
	EMISSION = haze_color * haze;
	if (rim > 0.0) {
		EMISSION += vec3(1.0, 0.93, 0.82) * pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0) * rim;
	}
	ROUGHNESS = 1.0;
}

void light() {
	// Soft two-tone shading with a pigment-noise edge instead of a smooth gradient.
	float edge = noise(world_pos * 3.1) - 0.5;
	float lit = smoothstep(-0.12, 0.38, dot(NORMAL, LIGHT) + edge * 0.3);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * lit / PI;
}

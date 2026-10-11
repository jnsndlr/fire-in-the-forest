shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec4 deep_color : source_color = vec4(0.27, 0.50, 0.45, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.46, 0.67, 0.59, 1.0);
uniform vec4 glint_color : source_color = vec4(0.95, 0.97, 0.90, 1.0);
uniform vec4 haze_color : source_color = vec4(0.90, 0.90, 0.78, 1.0);
varying vec3 pos;

float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453); }
float noise(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() { pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }

void fragment() {
	float flow = TIME * 0.35;
	float n = noise(vec3(pos.x * 0.45 - flow, 0.0, pos.z * 0.9));
	vec3 color = mix(deep_color.rgb, shallow_color.rgb, smoothstep(0.25, 0.85, n));
	// Long horizontal ripple glints, broken up so they read as painted strokes.
	float lines = sin(pos.z * 7.0 + n * 7.0 + TIME * 0.9);
	float breakup = smoothstep(0.45, 0.75, noise(vec3(pos.x * 1.2 - flow * 2.0, 3.0, pos.z * 2.5)));
	color = mix(color, glint_color.rgb, smoothstep(0.93, 1.0, lines) * breakup * 0.85);
	// Crisp broken foam where the water meets the bank (UV.x = local water depth).
	float edge = UV.x + (noise(vec3(pos.x * 2.2, TIME * 0.4, pos.z * 2.2)) - 0.5) * 0.12;
	color = mix(color, glint_color.rgb, step(edge, 0.09));
	float haze = 1.0 - exp(-clamp(-pos.z, 0.0, 80.0) * 0.06);
	ALBEDO = mix(color, haze_color.rgb, haze);
}

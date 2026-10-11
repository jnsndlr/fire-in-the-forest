shader_type spatial;
render_mode specular_disabled;

// Forest floor: world-anchored patches of meadow grass and leaf-litter earth,
// scattered fallen-leaf flecks, sun dapples, soil/rock banks on side faces,
// and the same depth haze as the pigment shader.
uniform vec4 grass_color : source_color = vec4(0.58, 0.66, 0.36, 1.0);
uniform vec4 grass_light : source_color = vec4(0.72, 0.76, 0.45, 1.0);
uniform vec4 earth_color : source_color = vec4(0.66, 0.53, 0.42, 1.0);
uniform vec4 leaf_color : source_color = vec4(0.80, 0.58, 0.36, 1.0);
uniform vec4 bank_color : source_color = vec4(0.60, 0.47, 0.40, 1.0);
uniform vec4 haze_low : source_color = vec4(0.88, 0.89, 0.76, 1.0);
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
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 p = world_pos;
	float wash = noise(p * 1.6) * 0.6 + noise(p * 5.5) * 0.4;
	// Large meadow vs leaf-litter zones with ragged painted edges.
	float zone = noise(vec3(p.x * 0.045, 0.0, p.z * 0.08)) * 0.75 + noise(p * 0.35) * 0.25;
	float grass = smoothstep(0.36, 0.52, zone + (wash - 0.5) * 0.25);
	vec3 meadow = mix(grass_color.rgb, grass_light.rgb, noise(p * 0.9));
	vec3 earth = earth_color.rgb * (0.9 + wash * 0.2);
	// Fallen leaves: small crisp flecks, denser on bare earth.
	float leaves = step(0.84 - (1.0 - grass) * 0.06, noise(vec3(p.x * 6.0, 0.0, p.z * 9.0) + noise(p * 2.0)));
	vec3 color = mix(earth, meadow, grass);
	color = mix(color, leaf_color.rgb * (0.85 + wash * 0.3), leaves * 0.55);
	// Sun dapples through the canopy.
	float dapple = smoothstep(0.55, 0.7, noise(vec3(p.x * 0.4 + p.z * 0.2, 7.0, p.z * 0.6)));
	color *= 0.92 + dapple * 0.18;
	float top = smoothstep(0.5, 0.8, world_normal.y);
	vec3 bank = bank_color.rgb * (0.85 + noise(vec3(p.x * 2.0, p.y * 9.0, p.z * 2.0)) * 0.3);
	color = mix(bank, color, top);
	float haze = 1.0 - exp(-clamp(-p.z, 0.0, 120.0) * haze_density);
	vec3 haze_color = mix(haze_low.rgb, haze_high.rgb, smoothstep(-2.0, 28.0, p.y));
	ALBEDO = color * (1.0 - haze);
	EMISSION = haze_color * haze;
	ROUGHNESS = 1.0;
}

void light() {
	float edge = noise(world_pos * 3.1) - 0.5;
	float lit = smoothstep(-0.12, 0.38, dot(NORMAL, LIGHT) + edge * 0.3);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * lit / PI;
}

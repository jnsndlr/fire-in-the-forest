shader_type spatial;
render_mode diffuse_burley, specular_disabled;
uniform vec4 paint_color : source_color = vec4(0.5, 0.6, 0.3, 1.0);
uniform float pigment_strength = 0.13;
varying vec3 paint_position;
float hash(vec3 p) { return fract(sin(dot(p, vec3(127.1,311.7,74.7))) * 43758.5453); }
float noise(vec3 p) {
 vec3 i = floor(p); vec3 f = fract(p); f = f*f*(3.0-2.0*f);
 return mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z);
}
void vertex() { paint_position = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz; }
void fragment() {
 float wash = noise(paint_position*1.9)*0.65 + noise(paint_position*7.0)*0.35;
 ALBEDO = paint_color.rgb * (1.0 + (wash-0.5)*pigment_strength*2.0);
 ROUGHNESS = 1.0;
}

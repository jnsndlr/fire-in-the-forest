shader_type spatial;
render_mode unshaded, cull_disabled;
varying vec3 pos;
void vertex() { pos = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz; }
void fragment() {
 float ripples = sin(pos.x*8.0 + sin(pos.z*5.0) + TIME*1.6);
 float fleck = smoothstep(0.97,1.0,ripples)*smoothstep(0.3,0.8,sin(pos.z*13.0+pos.x));
 ALBEDO = mix(vec3(0.25,0.49,0.43),vec3(0.88,0.94,0.80),fleck*0.75);
}

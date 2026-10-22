shader_type spatial;
// Wooden boards for the floor and walls: per-board tone, grain streaks, dark seams, board ends.

uniform vec3 base : source_color = vec3(0.36, 0.24, 0.16);
uniform float boards = 8.0;
uniform bool vertical = false;
uniform vec2 uv_scale = vec2(4.0, 4.0);

float h1(float x) { return fract(sin(x * 127.1) * 43758.5453); }
float n2(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = h1(i.x + i.y * 57.0), b = h1(i.x + 1.0 + i.y * 57.0);
	float c = h1(i.x + (i.y + 1.0) * 57.0), d = h1(i.x + 1.0 + (i.y + 1.0) * 57.0);
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	vec2 uv = UV * uv_scale;
	if (vertical) uv = uv.yx;
	float row = floor(uv.y * boards);
	float fy = fract(uv.y * boards);
	float along = uv.x + h1(row) * 3.0;
	float seg = floor(along * 0.7);
	float tone = 0.78 + 0.35 * h1(row * 3.1 + seg * 7.7);
	float grain = n2(vec2(along * 3.0, fy * 22.0 + row * 9.0)) * 0.6 + n2(vec2(along * 18.0, fy * 60.0)) * 0.4;
	vec3 col = base * tone * (0.82 + 0.3 * grain);
	float seam = smoothstep(0.0, 0.03, fy) * smoothstep(1.0, 0.97, fy);
	float end = smoothstep(0.0, 0.01, fract(along * 0.7)) * smoothstep(1.0, 0.99, fract(along * 0.7));
	col *= mix(0.35, 1.0, seam * end);
	ALBEDO = col;
	ROUGHNESS = 0.78 - grain * 0.1;
	SPECULAR = 0.35;
}

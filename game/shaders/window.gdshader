shader_type spatial;
// Dusk sky through the window: gradient, distant tree line, a few early stars, muntins.
render_mode unshaded;

float h1(float x) { return fract(sin(x * 91.7) * 43758.5453); }

void fragment() {
	vec2 uv = UV;
	vec3 top = vec3(0.11, 0.13, 0.25);
	vec3 mid = vec3(0.36, 0.29, 0.43);
	vec3 low = vec3(0.79, 0.54, 0.36);
	float y = 1.0 - uv.y;
	vec3 col = mix(low, mid, smoothstep(0.1, 0.45, y));
	col = mix(col, top, smoothstep(0.45, 1.0, y));
	float trees = 0.2 + 0.06 * abs(sin(uv.x * 14.0)) + 0.04 * h1(floor(uv.x * 40.0));
	col = mix(col, vec3(0.06, 0.05, 0.07), step(y, trees));
	vec2 sc = floor(uv * vec2(60.0, 75.0));
	float star = step(0.995, h1(sc.x * 13.0 + sc.y * 71.0)) * smoothstep(0.55, 0.9, y);
	col += star * 0.8;
	float mx = step(abs(uv.x - 0.5), 0.012) + step(abs(uv.y - 0.5), 0.01);
	col = mix(col, vec3(0.1, 0.06, 0.04), clamp(mx, 0.0, 1.0));
	ALBEDO = col * 1.4;
}

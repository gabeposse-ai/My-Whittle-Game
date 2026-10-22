// Shared maths for the log's shape. This file is included by BOTH the compute shaders (GLSL 450)
// and the render shaders (Godot shading language), so it may only contain plain functions written
// in the common subset of the two languages: no uniforms, no built-ins, no overloading.
//
// Frames: "local" = inches from the log centre, log axis (= grain) along +y.

uint wm_pcg(uint v) {
	uint state = v * 747796405u + 2891336453u;
	uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
	return (word >> 22u) ^ word;
}

float wm_hash3(ivec3 p, uint seed) {
	uint h = wm_pcg(uint(p.x) ^ wm_pcg(uint(p.y) ^ wm_pcg(uint(p.z) ^ seed)));
	return float(h) * (1.0 / 4294967295.0);
}

// Trilinear value noise in [0, 1].
float wm_vnoise(vec3 x, uint seed) {
	vec3 fl = floor(x);
	ivec3 i = ivec3(fl);
	vec3 f = x - fl;
	f = f * f * (3.0 - 2.0 * f);
	float c000 = wm_hash3(i, seed);
	float c100 = wm_hash3(i + ivec3(1, 0, 0), seed);
	float c010 = wm_hash3(i + ivec3(0, 1, 0), seed);
	float c110 = wm_hash3(i + ivec3(1, 1, 0), seed);
	float c001 = wm_hash3(i + ivec3(0, 0, 1), seed);
	float c101 = wm_hash3(i + ivec3(1, 0, 1), seed);
	float c011 = wm_hash3(i + ivec3(0, 1, 1), seed);
	float c111 = wm_hash3(i + ivec3(1, 1, 1), seed);
	return mix(mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y),
			mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y), f.z);
}

// Two-octave fractal noise centred on 0, roughly in [-0.5, 0.5].
float wm_fbm(vec3 x, uint seed) {
	return (wm_vnoise(x, seed) - 0.5) * 0.67 + (wm_vnoise(x * 2.03, seed + 7u) - 0.5) * 0.33;
}

// Radius (inches) of the uncarved log at height y and angle theta: natural wobble and taper.
float wm_original_radius(float y, float theta, float radius, float len, uint seed) {
	float c = cos(theta);
	float s = sin(theta);
	float wobble = wm_fbm(vec3(c * 1.3 + 11.0, s * 1.3, y * 0.22), seed) * 0.09 + sin(3.0 * theta + y * 0.15) * 0.012;
	float taper = 1.0 - 0.025 * (y / len);
	return radius * taper * (1.0 + wobble);
}

float wm_bark_thickness(float y, float theta, float bark_inch, uint seed) {
	float n = wm_fbm(vec3(cos(theta) * 4.0, sin(theta) * 4.0, y * 0.8), seed + 3u);
	return bark_inch * (0.75 + 0.5 * (n + 0.5));
}

// 0..1: how much a local point lies in the original bark shell.
float wm_bark_amount(vec3 p, float radius, float len, float bark_inch, uint seed) {
	float r = length(p.xz);
	float theta = atan(p.z, p.x);
	float inner = wm_original_radius(p.y, theta, radius, len, seed) - wm_bark_thickness(p.y, theta, bark_inch, seed);
	float t = clamp((r - inner) / 0.03 + 0.5, 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// Signed distance (inches, negative inside) of the uncarved log: a wobbly cylinder with
// slightly tilted, rough saw-cut ends.
float wm_log_sdf(vec3 p, float radius, float len, uint seed) {
	float half_len = len * 0.5;
	float r = length(p.xz);
	float theta = atan(p.z, p.x);
	float side = r - wm_original_radius(p.y, theta, radius, len, seed);
	float top = p.y - (half_len - 0.04 * p.x + wm_fbm(vec3(p.x * 2.0, p.z * 2.0, 5.0), seed) * 0.05);
	float bot = -p.y - (half_len + 0.03 * p.z + wm_fbm(vec3(p.x * 2.0, p.z * 2.0, 9.0), seed) * 0.05);
	return max(side, max(top, bot));
}

// Procedural wood appearance shared by the log, offcuts, curls and flakes. Colour is computed from a
// point's position inside the ORIGINAL log (inches, axis = +y), so every surface shows the correct
// interior: rings on end grain, stripes on side grain, heartwood/sapwood, knots, and bark.
// Requires wood_math.gdshaderinc to be included first.

uniform vec3 sap_color : source_color = vec3(0.92, 0.85, 0.71);
uniform vec3 heart_color : source_color = vec3(0.88, 0.79, 0.63);
uniform vec3 bark_color : source_color = vec3(0.42, 0.35, 0.28);
uniform vec3 bark_dark : source_color = vec3(0.23, 0.19, 0.15);
uniform float late_mul = 0.88;
uniform float rings_per_inch = 7.0;
uniform float heart_radius = 0.0;
uniform float figure = 0.06;
uniform float log_radius = 3.0;
uniform float log_length = 12.0;
uniform float bark_inch = 0.1;
uniform int log_seed = 1;
uniform vec4 knots[4];
uniform int knot_count = 0;

vec3 wood_color(vec3 p) {
	uint seed = uint(log_seed);
	vec3 sp = p + vec3(float(log_seed % 1000) * 0.137);
	// Rings wander: low-frequency warp so they are not perfect circles.
	float warp = (wm_vnoise(sp * vec3(0.55, 0.06, 0.55), seed) - 0.5) * 0.45
			+ (wm_vnoise(sp * vec3(2.2, 0.25, 2.2), seed + 11u) - 0.5) * 0.08;
	// Knots deflect the grain around them and carry their own tight rings.
	float knot_mask = 0.0;
	float knot_ring = 0.0;
	for (int i = 0; i < 4; i++) {
		if (i >= knot_count) break;
		vec4 k = knots[i];
		vec3 d = normalize(vec3(cos(k.y), k.z, sin(k.y)));
		vec3 v = p - vec3(0.0, k.x, 0.0);
		float t = dot(v, d);
		if (t < 0.0) continue;
		float dist = length(v - d * t);
		float kr = 0.05 + t * 0.075;
		warp += 0.5 * kr * exp(-dist * dist / (kr * kr * 5.0));
		float body = 1.0 - smoothstep(kr * 0.85, kr * 1.1, dist);
		if (body > knot_mask) {
			knot_mask = body;
			knot_ring = fract(dist * 18.0);
		}
	}
	float r = length(p.xz) + warp;
	float ring = fract(r * rings_per_inch);
	// Earlywood darkens gradually into latewood, then snaps back at the next ring boundary.
	float late = smoothstep(0.45, 0.93, ring) * (1.0 - smoothstep(0.93, 1.0, ring));
	float heart = heart_radius > 0.0 ? 1.0 - smoothstep(heart_radius - 0.1, heart_radius + 0.1, r) : 0.0;
	vec3 base = mix(sap_color, heart_color, heart);
	vec3 col = mix(base, base * late_mul, late);
	// Fibres run along the log axis: noise stretched along y.
	float fib = wm_vnoise(vec3(p.x * 34.0, p.y * 1.1, p.z * 34.0), seed + 21u);
	float fib2 = wm_vnoise(vec3(p.x * 90.0, p.y * 3.0, p.z * 90.0), seed + 22u);
	col *= 1.0 + figure * ((fib - 0.5) * 1.6 + (fib2 - 0.5) * 0.8);
	col *= 0.94 + 0.12 * wm_vnoise(sp * 0.7, seed + 23u);
	col *= 1.0 - 0.35 * (1.0 - smoothstep(0.03, 0.09, length(p.xz))); // pith
	vec3 knot_col = heart_color * 0.42 * (0.8 + 0.25 * smoothstep(0.3, 0.9, knot_ring));
	return mix(col, knot_col, knot_mask);
}

vec3 bark_shade(vec3 p) {
	// Fissures run along the trunk: high frequency around the circumference, low along y.
	vec2 dir = normalize(p.xz + vec2(1e-4));
	uint seed = uint(log_seed);
	float a = wm_vnoise(vec3(dir * 9.0, p.y * 0.35), seed + 31u);
	float b = wm_vnoise(vec3(dir * 21.0 + 5.0, p.y * 0.8), seed + 32u);
	float ridge = abs(a * 2.0 - 1.0) * 0.65 + abs(b * 2.0 - 1.0) * 0.35;
	float fissure = smoothstep(0.04, 0.3, ridge);
	vec3 col = mix(bark_dark, bark_color, fissure);
	col *= 0.85 + 0.25 * smoothstep(0.45, 0.9, ridge);
	col *= 0.9 + 0.2 * wm_vnoise(p * vec3(5.0, 1.5, 5.0), seed + 33u);
	return col;
}

float bark_at(vec3 p) {
	return wm_bark_amount(p, log_radius, log_length, bark_inch, uint(log_seed));
}

#[compute]
#version 450
// Sphere-traces pointer rays (grid space) against the SDF; returns the hit point and normal.

layout(local_size_x = 8, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler3D sdf;
layout(set = 0, binding = 1, std430) restrict readonly buffer Rays { vec4 rays[]; };  // origin, dir pairs
layout(set = 0, binding = 2, std430) restrict writeonly buffer Hits { vec4 hits[]; }; // (pos, found), (normal, t)

layout(push_constant, std430) uniform Params {
	vec4 dims; // nx, ny, nz, count
} pc;

float S(vec3 g) {
	return textureLod(sdf, (g + 0.5) / pc.dims.xyz, 0.0).r;
}

void main() {
	int i = int(gl_GlobalInvocationID.x);
	if (i >= int(pc.dims.w)) return;
	vec3 o = rays[i * 2].xyz;
	vec3 d = normalize(rays[i * 2 + 1].xyz);
	vec3 lo = vec3(1.0), hi = pc.dims.xyz - 2.0;
	vec3 inv = 1.0 / d;
	vec3 t0s = (lo - o) * inv, t1s = (hi - o) * inv;
	vec3 tmin = min(t0s, t1s), tmax = max(t0s, t1s);
	float t0 = max(max(tmin.x, tmin.y), max(tmin.z, 0.0));
	float t1 = min(min(tmax.x, tmax.y), tmax.z);
	hits[i * 2] = vec4(0.0);
	hits[i * 2 + 1] = vec4(0.0);
	if (t0 > t1) return;
	float t = t0;
	float v = S(o + d * t);
	if (v < 0.0) return;
	for (int k = 0; k < 512 && t < t1; k++) {
		float pt = t;
		t += max(0.3, v * 0.8);
		v = S(o + d * t);
		if (v < 0.0) {
			float a = pt, b = t;
			for (int j = 0; j < 12; j++) {
				float m = 0.5 * (a + b);
				if (S(o + d * m) < 0.0) b = m; else a = m;
			}
			vec3 p = o + d * a;
			float h = 0.75;
			vec3 n = vec3(S(p + vec3(h, 0, 0)) - S(p - vec3(h, 0, 0)),
					S(p + vec3(0, h, 0)) - S(p - vec3(0, h, 0)),
					S(p + vec3(0, 0, h)) - S(p - vec3(0, 0, h)));
			hits[i * 2] = vec4(p, 1.0);
			hits[i * 2 + 1] = vec4(normalize(n), a);
			return;
		}
	}
}

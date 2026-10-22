#[compute]
#version 450
// Carving as CSG subtraction on the SDF: f = max(f, -cutter(g)). One dispatch applies a batch of
// cutter segments over a grid box. All units are voxels (grid space); the grain runs along +y.

#include "wood_math.gdshaderinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(set = 0, binding = 0, r16f) uniform restrict image3D sdf;

struct Seg {
	vec4 a; // capsule/vee: start (xyz), radius (w) | saw: origin | half-space: (unused), offset (w)
	vec4 b; // end (xyz), kind (w): 0 capsule, 1 vee, 2 saw, 3 half-space
	vec4 n; // surface normal (xyz), tear-out amplitude in voxels (w)
	vec4 t; // stroke tangent / saw kerf normal (xyz), fuzz amplitude in voxels (w)
	vec4 e; // vee: cos(half angle), sin(half angle) | saw: half kerf, depth | noise: vpi (z)
};
layout(set = 0, binding = 1, std430) restrict readonly buffer Segs { Seg segs[]; };

layout(push_constant, std430) uniform Params {
	ivec4 origin;
	ivec4 size;
	ivec4 info; // count, clamp*1000
	vec4 noise; // vpi
} pc;

float seg_dist(Seg s, vec3 g, float vpi) {
	int kind = int(s.b.w + 0.5);
	vec3 pin = g / vpi; // inches, for noise frequencies independent of resolution
	if (kind == 0) {
		vec3 ab = s.b.xyz - s.a.xyz;
		vec3 pa = g - s.a.xyz;
		float h = clamp(dot(pa, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
		float d = length(pa - ab * h) - s.a.w;
		// Tear-out follows the fibres: noise stretched along the grain pulls the cutter in streaks.
		if (s.n.w > 0.0) d -= s.n.w * wm_vnoise(vec3(pin.x * 6.0, pin.y * 1.2, pin.z * 6.0), 17u);
		if (s.t.w > 0.0) d -= s.t.w * wm_vnoise(pin * 14.0, 5u);
		return d;
	}
	if (kind == 1) {
		vec3 side = normalize(cross(s.t.xyz, s.n.xyz));
		vec3 ab = s.b.xyz - s.a.xyz;
		vec3 pa = g - s.a.xyz;
		float h = clamp(dot(pa, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
		vec3 q = pa - ab * h;
		float u = abs(dot(q, side));
		float v = dot(q, s.n.xyz);
		float along = abs(dot(q, s.t.xyz));
		float d = max(max(u * s.e.x - v * s.e.y, along - 0.2), -v);
		if (s.n.w > 0.0) d -= s.n.w * 0.6 * wm_vnoise(vec3(pin.x * 6.0, pin.y * 1.2, pin.z * 6.0), 17u);
		if (s.t.w > 0.0) d -= s.t.w * 0.6 * wm_vnoise(pin * 14.0, 5u);
		return d;
	}
	if (kind == 2) {
		vec3 pa = g - s.a.xyz;
		float slab = abs(dot(pa, s.t.xyz)) - s.e.x;
		float below = -dot(pa, s.n.xyz) - s.e.y;
		return max(slab, below);
	}
	// Half-space: everything with dot(n, g) + w > 0 is removed.
	return -(dot(s.n.xyz, g) + s.a.w);
}

void main() {
	ivec3 lg = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(lg, pc.size.xyz))) return;
	ivec3 g = pc.origin.xyz + lg;
	float f = imageLoad(sdf, g).r;
	float clamp_v = float(pc.info.y) * 0.001;
	if (f >= clamp_v) return;
	vec3 gf = vec3(g);
	float nf = f;
	for (int i = 0; i < pc.info.x; i++) {
		nf = max(nf, -seg_dist(segs[i], gf, pc.noise.x));
	}
	if (nf > f) imageStore(sdf, g, vec4(min(nf, clamp_v)));
}

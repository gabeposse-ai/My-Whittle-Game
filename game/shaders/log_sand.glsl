#[compute]
#version 450
// Sandpaper: relax the SDF toward the average of its neighbours (a local Laplacian smooth), reading
// from a scratch copy so the result doesn't depend on thread order. Never adds wood back.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(set = 0, binding = 0, r16f) uniform restrict image3D sdf;
layout(set = 0, binding = 1, r16f) uniform restrict readonly image3D src;

layout(push_constant, std430) uniform Params {
	ivec4 origin;
	ivec4 size;
	vec4 centre; // xyz, radius (voxels)
	vec4 p;      // weight, shave
} pc;

void main() {
	ivec3 lg = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(lg, pc.size.xyz))) return;
	ivec3 g = pc.origin.xyz + lg;
	float f = imageLoad(src, g).r;
	if (abs(f) > 2.5) return;
	float r = length(vec3(g) - pc.centre.xyz) / pc.centre.w;
	if (r >= 1.0) return;
	float avg = (imageLoad(src, g + ivec3(1, 0, 0)).r + imageLoad(src, g - ivec3(1, 0, 0)).r
			+ imageLoad(src, g + ivec3(0, 1, 0)).r + imageLoad(src, g - ivec3(0, 1, 0)).r
			+ imageLoad(src, g + ivec3(0, 0, 1)).r + imageLoad(src, g - ivec3(0, 0, 1)).r) / 6.0;
	float w = (1.0 - r * r) * pc.p.x;
	float nf = max(f, f + (avg - f) * w + pc.p.y * w);
	imageStore(sdf, g, vec4(nf));
}

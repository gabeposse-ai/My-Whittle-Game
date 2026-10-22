#[compute]
#version 450
// Fills the SDF volume with an uncarved log. Values are signed distances in VOXELS, clamped.

#include "wood_math.gdshaderinc"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(set = 0, binding = 0, r16f) uniform restrict writeonly image3D sdf;

layout(push_constant, std430) uniform Params {
	vec4 dims;   // nx, ny, nz, vpi
	vec4 centre; // cx, cy, cz, clamp
	vec4 log_p;  // radius, length, bark_inch, seed
} pc;

void main() {
	ivec3 g = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(g, ivec3(pc.dims.xyz)))) return;
	float vpi = pc.dims.w;
	vec3 p = (vec3(g) - pc.centre.xyz) / vpi;
	float f = wm_log_sdf(p, pc.log_p.x, pc.log_p.y, uint(pc.log_p.w)) * vpi;
	f = clamp(f, -pc.centre.w, pc.centre.w);
	imageStore(sdf, g, vec4(f));
}

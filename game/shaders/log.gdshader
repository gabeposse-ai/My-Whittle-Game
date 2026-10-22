shader_type spatial;
// Renders the carved log by sphere-tracing its signed distance field on the GPU. The box mesh is only
// a bounding volume; every visible pixel comes from the SDF, so carved facets are exact at any zoom.
// Works in every pass (colour, depth prepass, shadows): the ray is rebuilt from VERTEX + the pass's
// own projection, and DEPTH is written from the hit point.
render_mode cull_front, depth_draw_opaque;

#include "res://shaders/wood_math.gdshaderinc"
#include "res://shaders/wood_color.gdshaderinc"

uniform sampler3D sdf : filter_linear, repeat_disable;
uniform vec3 dims = vec3(64.0);
uniform vec3 centre = vec3(32.0);
uniform float vpi = 24.0;
uniform mat4 world_to_local;
uniform mat4 local_to_world;
// Optional clip plane in grid space: everything with dot(xyz, g) + w < 0 is hidden (offcut pieces).
uniform vec4 clip_plane = vec4(0.0);

float S(vec3 g) {
	float f = texture(sdf, (g + 0.5) / dims).r;
	if (clip_plane.x != 0.0 || clip_plane.y != 0.0 || clip_plane.z != 0.0) {
		f = max(f, -(dot(clip_plane.xyz, g) + clip_plane.w));
	}
	return f;
}

void fragment() {
	bool ortho = PROJECTION_MATRIX[3][3] > 0.5;
	vec3 ro_v = ortho ? vec3(VERTEX.xy, 0.0) : vec3(0.0);
	vec3 rd_v = ortho ? vec3(0.0, 0.0, -1.0) : normalize(VERTEX);
	vec3 ro_w = (INV_VIEW_MATRIX * vec4(ro_v, 1.0)).xyz;
	vec3 rd_w = (INV_VIEW_MATRIX * vec4(rd_v, 0.0)).xyz;
	// To grid space: local inches * vpi + centre.
	vec3 o = (world_to_local * vec4(ro_w, 1.0)).xyz * vpi + centre;
	vec3 d = normalize((world_to_local * vec4(rd_w, 0.0)).xyz);
	vec3 lo = vec3(1.0), hi = dims - 2.0;
	vec3 inv = 1.0 / d;
	vec3 ta = (lo - o) * inv, tb = (hi - o) * inv;
	vec3 tmin = min(ta, tb), tmax = max(ta, tb);
	float t0 = max(max(tmin.x, tmin.y), max(tmin.z, 0.0));
	float t1 = min(min(tmax.x, tmax.y), tmax.z);
	if (t0 > t1) discard;
	float t = t0;
	float v = S(o + d * t);
	bool hit = v < 0.0;
	float pt = t;
	for (int k = 0; k < 256 && !hit; k++) {
		pt = t;
		t += max(0.25, v * 0.85);
		if (t > t1) break;
		v = S(o + d * t);
		hit = v < 0.0;
	}
	if (!hit) discard;
	float a = pt, b = t;
	for (int j = 0; j < 8; j++) {
		float m = 0.5 * (a + b);
		if (S(o + d * m) < 0.0) b = m; else a = m;
	}
	vec3 g = o + d * b;
	float h = 0.6;
	vec3 n = normalize(vec3(S(g + vec3(h, 0, 0)) - S(g - vec3(h, 0, 0)),
			S(g + vec3(0, h, 0)) - S(g - vec3(0, h, 0)),
			S(g + vec3(0, 0, h)) - S(g - vec3(0, 0, h))));
	vec3 p = (g - centre) / vpi; // local inches
	vec3 pw = (local_to_world * vec4(p, 1.0)).xyz;
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(pw, 1.0);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	DEPTH = clip.z / clip.w * 0.5 + 0.5; // OpenGL: NDC z in [-1, 1]
#else
	DEPTH = clip.z / clip.w; // Vulkan/D3D12: NDC z already in [0, 1] (reversed)
#endif
	vec3 nw = normalize((transpose(world_to_local) * vec4(n, 0.0)).xyz);
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	float bark = bark_at(p);
	ALBEDO = mix(wood_color(p), bark_shade(p), bark);
	ROUGHNESS = mix(0.52, 0.95, bark);
	SPECULAR = mix(0.45, 0.2, bark);
}

shader_type spatial;
// Curls, flakes and dust motes. Each vertex (or particle) carries the log-local position it was cut
// from, so a shaving shows exactly the rings/heartwood/bark that came off. Thin wood lets light
// through: BACKLIGHT gives curls their warm glow when the lamp is behind them.
render_mode cull_disabled;

#include "res://shaders/wood_math.gdshaderinc"
#include "res://shaders/wood_color.gdshaderinc"

uniform bool use_instance_custom = false;
varying vec3 src;

void vertex() {
	src = use_instance_custom ? INSTANCE_CUSTOM.xyz : CUSTOM0.xyz;
}

void fragment() {
	float bark = bark_at(src);
	vec3 c = mix(wood_color(src), bark_shade(src), bark) * 1.04;
	ALBEDO = c;
	ROUGHNESS = mix(0.6, 0.95, bark);
	SPECULAR = 0.3;
	BACKLIGHT = c * mix(0.55, 0.05, bark);
}

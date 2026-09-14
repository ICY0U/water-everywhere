// Expanding foam-and-ripple crown created by a discrete water impact.
//
// Geometry follows the live water normal in WaterReactionSystem; this shader only owns the
// graphic language: two hard rings, a short-lived white core, and seeded breakup at the edge.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_disabled;

#include "res://shaders/particle_cel_light.gdshaderinc"

uniform vec3 foam_color : source_color = vec3(0.97, 0.99, 1.0);
uniform vec3 edge_color : source_color = vec3(0.67, 0.82, 0.90);
uniform float age : hint_range(0.0, 1.0) = 0.0;
uniform float seed = 0.0;
uniform float violence : hint_range(0.0, 1.0) = 0.5;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float radius = length(p);
	vec2 direction = p / max(radius, 0.0001);
	float growth = 1.0 - pow(1.0 - age, 3.0);
	float width = mix(0.22, 0.045, age);
	float outer = width - abs(radius - growth * 0.86);
	float inner = width * 0.55 - abs(radius - growth * 0.58);
	// The core SHRINKS rather than fading in place, and every term here must stay a signed
	// distance: positive inside its shape, negative outside. Scaling one by a fade factor breaks
	// that, because the factor reaches exactly zero and takes the sign with it — the term then
	// reads as "exactly on the edge" across the entire quad rather than "nowhere near it". With
	// max() pinned at 0, the mapping below produces ALPHA exactly 0.5, which is
	// ALPHA_SCISSOR_THRESHOLD, and a scissored fragment at the threshold is kept and drawn
	// OPAQUE: the whole 18 m quad turned solid white for the rest of the ring's life, and then
	// into a starburst as erosion ate direction-space cells out of it.
	float core = 0.45 * (1.0 - smoothstep(0.0, 0.38, age)) - radius;

	// Direction-space noise has no polar seam and tears the ring into cel-shaped clumps.
	float breakup = hash21(floor(direction * (7.0 + violence * 9.0) + seed * 31.0));
	float erosion = smoothstep(0.42, 1.0, age) * mix(0.35, 0.78, violence);
	float mask = max(max(outer, inner), core);
	mask = min(mask * 10.0 + 0.5, breakup - erosion + 0.62);

	ALPHA = clamp(mask, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALBEDO = mix(edge_color, foam_color, step(0.0, max(inner, core)));
}

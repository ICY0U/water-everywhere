// Draws a ripple ring on the water: hard-edged concentric rings that race outward, slow,
// thin, and break apart as they fade.
//
// Drawn on the plane mesh that ripple_particles.gdshader lays in the surface. Opaque for
// the same reason as spray_droplet.gdshader: a blended ring would be painted over by any
// wave between it and the camera.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, specular_disabled;

#include "res://shaders/particle_cel_light.gdshaderinc"

group_uniforms Look;
uniform vec3 albedo : source_color = vec3(0.86, 0.93, 0.97);
// Rings per ripple. A real drop leaves a train of them, the outer one leading.
uniform int ring_count : hint_range(1, 4) = 2;
// Gap between successive rings, as a fraction of the full radius.
uniform float ring_spacing : hint_range(0.0, 0.8) = 0.3;
// Ring width as a fraction of the full radius, at birth and at death.
//
// Thin: a heavy ring reads as a drawn circle rather than as a disturbance in the water.
uniform vec2 ring_width = vec2(0.13, 0.035);
// How far a ring breaks into dashes as it fades. 0 keeps it whole, which looks stamped on.
uniform float break_up : hint_range(0.0, 1.5) = 1.15;
group_uniforms;

varying flat float v_seed;
varying flat float v_age;

float hash21(vec2 p) {
	p = fract(p * vec2(233.34, 851.73));
	p += dot(p, p + 23.45);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	v_seed = INSTANCE_CUSTOM.x;
	v_age = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec2 point = UV * 2.0 - 1.0;
	float radius = length(point);

	// Fast at first and slowing, as a real capillary ring does. Rings are held inside the
	// quad so their outer edge is never clipped square.
	float growth = 1.0 - pow(1.0 - v_age, 3.0);
	float half_width = mix(ring_width.x, ring_width.y, v_age) * 0.5;
	float coverage = -1.0;
	for (int i = 0; i < ring_count; i++) {
		float ring_radius = growth * (1.0 - half_width) - float(i) * ring_spacing;
		if (ring_radius > 0.0) {
			coverage = max(coverage, (half_width - abs(radius - ring_radius)) / half_width);
		}
	}

	// Dashes, sampled on the ring's direction so they have no seam where the angle wraps.
	vec2 direction = point / max(radius, 0.0001);
	float dashes = value_noise(direction * 3.0 + vec2(v_seed * 71.0, v_seed * 29.0));
	dashes = clamp((dashes - 0.5) * 2.2 + 0.5, 0.0, 1.0);
	float erosion = smoothstep(0.3, 1.0, v_age) * break_up;

	ALPHA = clamp(min(coverage, dashes - erosion) * 8.0 + 0.5, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALBEDO = albedo;
}

// Test probe for tools/verify_spray.gd.
//
// Renders gerstner_waves.gdshaderinc into a float texture, one pixel per point of sea, so
// the particles' idea of where the water is can be read back and compared against
// WaveField on the CPU. `quantity` picks which three values each pixel carries; they are
// written as 0.5 + value * encode_scale so the check never depends on the buffer keeping
// negative numbers.
shader_type canvas_item;
render_mode blend_disabled, unshaded;

#include "res://shaders/gerstner_waves.gdshaderinc"

uniform int quantity = 0;
uniform vec2 area_min = vec2(-60.0);
uniform vec2 area_size = vec2(120.0);
uniform float encode_scale = 0.05;

void fragment() {
	vec2 point = area_min + UV * area_size;
	vec3 normal;
	float compression;
	vec3 displacement = wave_sample(point, wave_time, normal, compression);

	vec3 value;
	if (quantity == 0) {
		value = vec3(displacement.y, compression, wave_surface_height(point, wave_time) - sea_level);
	} else if (quantity == 1) {
		value = normal;
	} else if (quantity == 2) {
		value = wave_velocity(point, wave_time);
	} else if (quantity == 3) {
		// The cheap displacement-only path, checked separately from the full sample above.
		value = vec3(wave_displacement(point, wave_time).xz, 0.0);
	} else {
		// Calibration: fixed values that prove the encode/read-back round trip is linear.
		value = vec3(1.5, -2.25, 4.0);
	}
	COLOR = vec4(value * encode_scale + 0.5, 1.0);
}

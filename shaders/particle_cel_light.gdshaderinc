// Cel lighting for particles, on the same curve as cel.gdshader and ocean.gdshader, so
// spray and rain carry the banding of the water they come out of.
//
// This file DEFINES light(). A shader that includes it must not declare its own.

group_uniforms Cel;
uniform int light_bands : hint_range(2, 6) = 2;
uniform float band_softness : hint_range(0.0, 0.25) = 0.02;
// Low enough that each droplet has a clearly darker side. Spray is usually seen against
// foam, which is the same white it is, so the shading is what separates the two: a lump
// with a lit and a shaded half reads as an object above water rather than as part of it.
uniform float shadow_lift : hint_range(0.0, 1.0) = 0.42;
// Tints the shaded side rather than only darkening it, as cel.gdshader does.
uniform vec3 shadow_tint : source_color = vec3(0.52, 0.64, 0.80);
uniform float shadow_tint_strength : hint_range(0.0, 1.0) = 0.7;
uniform float shadow_threshold : hint_range(0.0, 1.0) = 0.22;
uniform float shadow_edge_softness : hint_range(0.001, 0.2) = 0.03;
group_uniforms;

// Snaps a 0..1 value onto hard bands. Identical to the curve in cel.gdshader.
float cel_quantize(float v, int bands, float softness) {
	float fb = float(bands);
	float scaled = clamp(v, 0.0, 1.0) * fb;
	float lower = floor(scaled);
	float frac_part = scaled - lower;
	// Half-width must stay under 0.5 or the smoothstep bounds invert and the step silently
	// becomes a smooth ramp. See ocean.gdshader for the full explanation.
	float half_width = clamp(softness * fb, 0.0005, 0.49);
	float edge = smoothstep(0.5 - half_width, 0.5 + half_width, frac_part);
	return clamp((lower + edge) / fb, 0.0, 1.0);
}

// Collapses the shadow map's dithered penumbra back to a hard edge. See ocean.gdshader.
float cel_shadow(float attenuation) {
	return smoothstep(
		shadow_threshold - shadow_edge_softness,
		shadow_threshold + shadow_edge_softness,
		attenuation);
}

void light() {
	// Half-lambert, then hard-banded, with a cast shadow folded into the same band so a
	// droplet in a crest's shadow lands on exactly the colour of its own dark side.
	float wrapped = dot(normalize(NORMAL), normalize(LIGHT)) * 0.5 + 0.5;
	float banded = min(cel_quantize(wrapped, light_bands, band_softness), cel_shadow(ATTENUATION));
	float lit = mix(shadow_lift, 1.0, banded);
	float tint_weight = banded * shadow_tint_strength + (1.0 - shadow_tint_strength);
	DIFFUSE_LIGHT += mix(ALBEDO * shadow_tint, ALBEDO, tint_weight) * LIGHT_COLOR * lit;
}

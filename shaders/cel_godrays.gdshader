// Cel-shaded god rays: banded volumetric shafts over the ocean.
//
// This is a fog shader, so it runs once per froxel of Godot's volumetric fog grid that is
// touched by the FogVolume's AABB. It only writes DENSITY, ALBEDO and EMISSION; the
// engine does the light injection, the shadow lookup and the front-to-back integration.
// That matters: the shafts come from the sun's SHADOW being written into the froxel grid,
// which is why this file contains no raymarching and no light direction. Godot's fog is
// already the froxel technique the AAA references describe (Wronski 2014, Hillaire 2015),
// so the job here is not to reimplement it - it is to stop it looking smooth.
//
// Because a plain density field integrates to a smooth gradient, which is exactly the
// soft falloff the rest of the project exists to avoid, density is QUANTISED here. Fog
// then accumulates in discrete slabs and the shafts read as flat-edged shapes, matching
// the hard bands in ocean.gdshader rather than hazing them out.
//
// See docs/lighting_research.md for why this is a fog shader rather than a screen-space
// radial blur: screen-space shafts need the sun to be on screen, and this camera can look
// anywhere.
shader_type fog;

group_uniforms Density;
// Overall thickness. Kept very low by default: god rays want thin air and a bright sun,
// not thick fog, or the water's colour bands wash out.
uniform float density : hint_range(0.0, 1.0) = 0.035;
// Hard steps the density is snapped to. This is the cel dial - fewer bands is more
// graphic. 0 disables quantisation and gives ordinary smooth fog.
uniform int density_bands : hint_range(0, 16) = 5;
// Half-width of the blend across a band edge, in band units. A little softness stops the
// slab boundaries crawling as the froxel grid reprojects.
uniform float band_softness : hint_range(0.0, 0.49) = 0.12;
group_uniforms;

group_uniforms Height;
// Sea level, in world units. Fog is thickest here and thins with altitude, which is what
// keeps the horizon hazy while the sky above stays clean.
uniform float floor_height = 0.0;
// Height over which density falls to nothing.
uniform float falloff_height : hint_range(0.1, 400.0) = 45.0;
// Curve of that falloff. 1 is linear; higher hugs the water more tightly.
uniform float falloff_power : hint_range(0.1, 8.0) = 2.0;
group_uniforms;

group_uniforms Drift;
// Slow noise breaks the fog into patches so shafts are not perfectly even. Costs one
// noise evaluation per froxel, so it is deliberately a cheap value noise rather than FBM.
uniform float patch_strength : hint_range(0.0, 1.0) = 0.45;
uniform float patch_scale : hint_range(0.001, 0.2) = 0.012;
uniform vec2 patch_drift = vec2(0.35, 0.12);
// Driven from ocean.gd, NOT the built-in TIME.
//
// The project runs one clock: the CPU wave field, the ocean shader and this must all
// agree, or the fog drifts at a different rate from the water under Engine.time_scale or
// while paused. See ocean.gdshader for the same reasoning.
uniform float fog_time = 0.0;
group_uniforms;

group_uniforms Color;
// Scattering colour. Should track the weather's sky, or the shafts read as belonging to a
// different scene from the one lighting them - the same trap WeatherPreset exists to stop.
uniform vec3 albedo : source_color = vec3(0.72, 0.85, 0.95);
// Light the fog emits regardless of the sun. Small values lift deep shadow so the volume
// never goes fully black, which is the volumetric equivalent of shadow_lift.
uniform vec3 emission : source_color = vec3(0.0);
uniform float emission_energy : hint_range(0.0, 4.0) = 0.0;
group_uniforms;

group_uniforms Edges;
// Fades density out near the FogVolume's boundary so the box does not show as a hard
// rectangle in the air. SDF is negative inside the volume, so this works in metres.
uniform float edge_fade : hint_range(0.0, 60.0) = 12.0;
group_uniforms;

// Cheap 3D value noise. Deliberately not FBM: this runs per froxel per frame, and the
// shape only needs to be lumpy, not detailed.
float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	// Smoothstep weights, so the lattice does not show as diamond creases.
	f = f * f * (3.0 - 2.0 * f);

	float n000 = hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));

	return mix(
		mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
		f.z);
}

// Same quantisation curve as ocean.gdshader and cel.gdshader, so the fog steps on the
// same kind of edge the surface bands do.
//
// As in those shaders, half_width must stay below 0.5 or the smoothstep bounds invert and
// the step silently degrades into a smooth ramp - which would quietly undo the entire
// point of this shader.
float cel_quantize(float v, int bands, float softness) {
	float fb = float(bands);
	float scaled = clamp(v, 0.0, 1.0) * fb;
	float lower = floor(scaled);
	float frac_part = scaled - lower;
	float half_width = clamp(softness, 0.0005, 0.49);
	float edge = smoothstep(0.5 - half_width, 0.5 + half_width, frac_part);
	return clamp((lower + edge) / fb, 0.0, 1.0);
}

void fog() {
	// Height falloff, in world space so it stays put as the volume follows the camera.
	float above = max(WORLD_POSITION.y - floor_height, 0.0);
	float height_t = clamp(1.0 - above / falloff_height, 0.0, 1.0);
	float profile = pow(height_t, falloff_power);

	// Drifting patches, so shafts vary along their length instead of being uniform slabs.
	if (patch_strength > 0.0) {
		vec3 sample_pos = WORLD_POSITION * patch_scale;
		sample_pos.xz += patch_drift * fog_time * patch_scale;
		float n = value_noise(sample_pos);
		profile *= mix(1.0, n, patch_strength);
	}

	// The cel step. Quantising the PROFILE rather than the final density keeps the
	// height curve and the noise both banded, so slabs stay put in world space instead of
	// sliding as the camera moves.
	if (density_bands > 0) {
		profile = cel_quantize(profile, density_bands, band_softness);
	}

	// Soften the volume's own boundary. SDF is negative inside, so -SDF is the distance in
	// from the surface.
	if (edge_fade > 0.0) {
		profile *= clamp(-SDF / edge_fade, 0.0, 1.0);
	}

	DENSITY = density * profile;
	ALBEDO = albedo;
	EMISSION = emission * emission_energy;
}

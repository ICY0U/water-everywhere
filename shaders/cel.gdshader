// General-purpose cel shader for everything that is not water.
//
// Pairs with ocean.gdshader: it uses the same quantisation curve and shadow lift, so
// props sitting in the water share the ocean's banding and read as one art style.
// Outlines are done here as inverted-hull in a second pass (see cel_outline.gdshader).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

group_uniforms Surface;
uniform vec3 albedo_color : source_color = vec3(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white,
		filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform bool use_normal_map = false;
uniform vec2 uv_scale = vec2(1.0, 1.0);
group_uniforms;

group_uniforms Cel;
uniform int light_bands : hint_range(2, 6) = 3;
uniform float band_softness : hint_range(0.0, 0.25) = 0.02;
uniform float shadow_lift : hint_range(0.0, 1.0) = 0.42;
// Tints the shadow bands rather than just darkening them - key to a painted cel look.
uniform vec3 shadow_tint : source_color = vec3(0.42, 0.52, 0.72);
uniform float shadow_tint_strength : hint_range(0.0, 1.0) = 0.35;
// Where the cast-shadow edge falls. See cel_shadow() for why this is thresholded at all.
uniform float shadow_threshold : hint_range(0.0, 1.0) = 0.22;
uniform float shadow_edge_softness : hint_range(0.001, 0.2) = 0.03;
group_uniforms;

group_uniforms Highlights;
uniform vec3 specular_color : source_color = vec3(1.0);
uniform float specular_size : hint_range(0.5, 256.0) = 24.0;
uniform float specular_strength : hint_range(0.0, 4.0) = 0.8;
// Rim light reads as the classic anime edge glow.
uniform vec3 rim_color : source_color = vec3(1.0, 0.95, 0.85);
uniform float rim_power : hint_range(0.5, 8.0) = 3.0;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.5;
group_uniforms;

varying vec3 world_normal;

// Identical quantisation curve to ocean.gdshader so both read as the same art style.
float cel_quantize(float v, int bands, float softness) {
	float fb = float(bands);
	float scaled = clamp(v, 0.0, 1.0) * fb;
	float lower = floor(scaled);
	float frac_part = scaled - lower;
	// Half-width must stay under 0.5 or the smoothstep bounds invert and the "step"
	// silently becomes a smooth ramp. See ocean.gdshader for the full explanation.
	float half_width = clamp(softness * fb, 0.0005, 0.49);
	float edge = smoothstep(0.5 - half_width, 0.5 + half_width, frac_part);
	return clamp((lower + edge) / fb, 0.0, 1.0);
}

// Collapses the shadow map's soft penumbra back to a hard cel edge. Godot's soft shadows
// are stochastic, so ATTENUATION arrives dithered; quantised lighting multiplied by that
// noise speckles instead of banding. See ocean.gdshader for the full explanation.
float cel_shadow(float attenuation) {
	return smoothstep(
		shadow_threshold - shadow_edge_softness,
		shadow_threshold + shadow_edge_softness,
		attenuation);
}

void vertex() {
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	UV = UV * uv_scale;
}

void fragment() {
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = albedo_color * tex.rgb;
	// ALPHA is deliberately NOT written, which is what keeps this material OPAQUE.
	//
	// Godot queues any spatial shader that assigns ALPHA as transparent, and a transparent
	// surface does not write depth under depth_draw_opaque, is drawn after everything
	// opaque, and is sorted against other transparent surfaces by object origin. For a
	// solid prop floating in the ocean every one of those is wrong: the ocean's rings are
	// centred on the camera, so they sort as the nearest transparent object and paint over
	// the prop entirely, and the prop never appears in the depth texture the water reads to
	// work out how deep it is. Staying opaque puts the prop in the depth prepass, which is
	// what lets the water occlude its submerged half and tint the water around it.
	//
	// A cut-out material (foliage, a chain-link rail) needs its own shader rather than a
	// flag here: the transparency is decided by whether ALPHA appears at all, not by
	// whether the branch that writes it is taken.

	if (use_normal_map) {
		NORMAL_MAP = texture(normal_texture, UV).xyz;
		NORMAL_MAP_DEPTH = normal_strength;
	}

	ROUGHNESS = 0.7;
	METALLIC = 0.0;
	SPECULAR = 0.4;
}

void light() {
	vec3 nrm = normalize(NORMAL);
	vec3 ldir = normalize(LIGHT);

	// Half-lambert, then hard-banded.
	float wrapped = dot(nrm, ldir) * 0.5 + 0.5;
	float banded = cel_quantize(wrapped, light_bands, band_softness);

	// A cast shadow and the unlit side of the form are the same thing to a cel painter:
	// both are "not reached by the sun", and both get the same flat shade. Folding the
	// thresholded shadow into the band term before lifting and tinting means a shadow
	// crossing a surface lands on exactly the colour the form's own dark side already
	// uses, instead of multiplying it darker and breaking the palette.
	float shadow = cel_shadow(ATTENUATION);
	banded = min(banded, shadow);

	float lit = mix(shadow_lift, 1.0, banded);

	// Tint the shadowed bands instead of only darkening them.
	float tint_weight = banded * shadow_tint_strength + (1.0 - shadow_tint_strength);
	vec3 shaded = mix(ALBEDO * shadow_tint, ALBEDO, tint_weight);
	DIFFUSE_LIGHT += shaded * LIGHT_COLOR * lit;

	// Hard-edged specular blob.
	vec3 h = normalize(ldir + normalize(VIEW));
	// Threshold near the top of pow()'s range so the highlight stays a tight shape
	// rather than flooding the lit half of the surface. See ocean.gdshader for detail.
	float spec = pow(max(dot(nrm, h), 0.0), specular_size);
	spec = smoothstep(0.75, 0.85, spec);
	SPECULAR_LIGHT += specular_color * spec * specular_strength * shadow * LIGHT_COLOR;

	// Rim light, gated by the light direction so it only appears on lit edges.
	float rim = pow(1.0 - clamp(dot(nrm, normalize(VIEW)), 0.0, 1.0), rim_power);
	rim = smoothstep(0.4, 0.5, rim) * clamp(dot(nrm, ldir) * 0.5 + 0.5, 0.0, 1.0);
	SPECULAR_LIGHT += rim_color * rim * rim_strength * shadow * LIGHT_COLOR;
}

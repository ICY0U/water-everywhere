// Cel-shaded sky with banded clouds.
//
// Everything is quantised. The sky gradient steps between horizon and zenith rather than
// blending, clouds are hard-thresholded noise lit in two or three flat tones, and the sun
// is a solid disc with a banded halo. Nothing here is physically derived: an atmospheric
// scattering model produces exactly the smooth gradients a cel look has to avoid.
//
// Weather is authored as discrete presets (see scenes/sky/*.tres) rather than blended from
// one dial, so each mood can be tuned without compromising the others.
//
// Clouds are lit from LIGHT0, so they turn with the scene's DirectionalLight3D and stay
// consistent with how the ocean below is lit.
shader_type sky;
render_mode use_half_res_pass;

// ---------------------------------------------------------------------------
// Sky gradient
// ---------------------------------------------------------------------------
group_uniforms Sky;
uniform vec3 horizon_color : source_color = vec3(0.71, 0.87, 0.95);
uniform vec3 zenith_color : source_color = vec3(0.19, 0.51, 0.84);
// Colour immediately around the sun, blended in by sun_glow_size.
uniform vec3 sun_glow_color : source_color = vec3(1.0, 0.93, 0.75);
// Hard steps between horizon and zenith. 0 disables banding for a smooth gradient.
uniform int sky_bands : hint_range(0, 12) = 5;
// Pulls the gradient toward the horizon. >1 compresses the horizon band.
uniform float horizon_falloff : hint_range(0.2, 8.0) = 2.2;
// Height below which the sky darkens toward the sea. Keeps the horizon line from glowing.
uniform vec3 below_horizon_color : source_color = vec3(0.45, 0.62, 0.72);
group_uniforms;

// ---------------------------------------------------------------------------
// Sun
// ---------------------------------------------------------------------------
group_uniforms Sun;
uniform vec3 sun_color : source_color = vec3(1.0, 0.97, 0.86);
// Angular radius of the solid disc, in radians.
uniform float sun_size : hint_range(0.0, 0.5) = 0.045;
uniform float sun_glow_size : hint_range(0.0, 2.0) = 0.45;
// Steps in the glow around the disc. The banding is what keeps it from reading as bloom.
uniform int sun_glow_bands : hint_range(1, 8) = 3;
uniform float sun_intensity : hint_range(0.0, 20.0) = 6.0;
group_uniforms;

// ---------------------------------------------------------------------------
// Clouds
// ---------------------------------------------------------------------------
group_uniforms Clouds;
uniform vec3 cloud_lit_color : source_color = vec3(1.0, 0.99, 0.96);
uniform vec3 cloud_mid_color : source_color = vec3(0.86, 0.89, 0.95);
uniform vec3 cloud_shadow_color : source_color = vec3(0.64, 0.69, 0.81);
// Fraction of sky covered. 0 is clear, 1 is solid overcast.
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.42;
// Edge hardness. Near 0 gives the crisp ink-like border of a painted cloud.
uniform float cloud_edge : hint_range(0.001, 0.4) = 0.03;
uniform float cloud_scale : hint_range(0.2, 12.0) = 2.6;
uniform float cloud_speed : hint_range(0.0, 0.2) = 0.012;
// Driven by WeatherController from Ocean.elapsed_time, so all peers see the same animation.
uniform float weather_time = 0.0;
uniform float cloud_wind_angle : hint_range(0.0, 360.0) = 45.0;
// Vertical squash. Clouds are wide and flat, not spherical.
uniform float cloud_flatten : hint_range(0.5, 6.0) = 2.4;
// How far above the horizon the cloud layer fades in, to keep the skyline clean.
uniform float cloud_horizon_fade : hint_range(0.0, 0.6) = 0.14;
// Detail octaves. More is wispier; fewer is bolder and more graphic.
uniform int cloud_octaves : hint_range(1, 6) = 4;
// Strength of the lit rim on the sunward side of each cloud.
uniform float cloud_light_wrap : hint_range(0.0, 1.0) = 0.55;
group_uniforms;

// ---------------------------------------------------------------------------
// Storm extras
// ---------------------------------------------------------------------------
group_uniforms Storm;
// Darkens cloud bases. Drives the heavy, oppressive read of a storm sky.
uniform float cloud_base_darkening : hint_range(0.0, 1.0) = 0.0;
// A second, higher-contrast cloud layer scrolling faster than the main one.
uniform float storm_layer_strength : hint_range(0.0, 1.0) = 0.0;
group_uniforms;


// Hash and value noise. Cheap, and the smoothstep interpolant keeps cloud edges from
// showing lattice artefacts once they are thresholded.
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

// Fractal sum. Each octave halves in amplitude and doubles in frequency, which is what
// gives clouds their self-similar billowed edges.
float fbm(vec2 p, int octaves) {
	float total = 0.0;
	float amplitude = 0.5;
	float normalisation = 0.0;
	for (int i = 0; i < octaves; i++) {
		total += value_noise(p) * amplitude;
		normalisation += amplitude;
		p *= 2.03;
		amplitude *= 0.5;
	}
	return total / max(normalisation, 0.0001);
}

// Fractal sum with the high-frequency octaves attenuated by `detail`.
//
// At detail = 1 this matches fbm exactly. As it falls to 0 each successive octave is
// weighted out, leaving only the broadest shape - a cheap band-limit that avoids the
// aliasing that a full-detail sum produces where the projection is heavily compressed.
float fbm_faded(vec2 p, int octaves, float detail) {
	float total = 0.0;
	float amplitude = 0.5;
	float normalisation = 0.0;
	for (int i = 0; i < octaves; i++) {
		// Octave 0 always contributes fully; later octaves need progressively more detail.
		float octave_weight = (i == 0)
			? 1.0
			: smoothstep(0.0, 1.0, clamp(detail * float(octaves) - float(i - 1), 0.0, 1.0));
		total += value_noise(p) * amplitude * octave_weight;
		normalisation += amplitude * octave_weight;
		p *= 2.03;
		amplitude *= 0.5;
	}
	return total / max(normalisation, 0.0001);
}

// Quantise 0..1 into hard steps.
//
// `softness` is the half-width of the blend at each band edge, in band units, and must stay
// below 0.5: at or above it the smoothstep bounds cross over and the step silently becomes
// a smooth ramp, which is the failure that makes a cel sky look like an ordinary gradient.
float cel_quantize(float v, int bands, float softness) {
	if (bands <= 0) {
		return clamp(v, 0.0, 1.0);
	}
	float fb = float(bands);
	float scaled = clamp(v, 0.0, 1.0) * fb;
	float lower = floor(scaled);
	float half_width = clamp(softness * fb, 0.0005, 0.49);
	float edge = smoothstep(0.5 - half_width, 0.5 + half_width, scaled - lower);
	return clamp((lower + edge) / fb, 0.0, 1.0);
}

// Projects a view direction onto a horizontal cloud plane above the camera.
//
// Sampling noise directly by EYEDIR.xz would wrap the pattern around the dome and pinch it
// at the zenith. Dividing by height lays the clouds on a flat sheet instead, so they
// foreshorten towards the horizon the way real cloud cover does in perspective.
//
// Near the horizon that projection runs away: dir.y approaches 0, the divisor collapses,
// and the sheet stretches without limit. Clamping the height only trades smearing for
// frozen radial curtains, because every direction below the clamp then samples the same
// runaway coordinate. The projection is left uncorrected here and the *detail* is faded out
// instead - see cloud_density - which removes the artefact rather than relocating it.
vec2 cloud_plane_uv(vec3 dir, float scroll) {
	float height = max(dir.y, 0.001);
	vec2 plane = dir.xz / (height * cloud_flatten);
	float angle = radians(cloud_wind_angle);
	vec2 wind = vec2(cos(angle), sin(angle)) * scroll;
	return plane * cloud_scale + wind;
}

// Cloud density at a view direction, 0..1 after thresholding.
//
// Detail octaves are dropped as the view approaches the horizon. The plane projection
// compresses ever more cloud into ever fewer pixels there, so the high-frequency octaves
// alias into streaks long before they carry any readable shape. Fading them leaves the
// broad low-frequency mass, which is what a distant cloud bank should look like anyway.
float cloud_density(vec3 dir, float scroll, int octaves) {
	vec2 uv = cloud_plane_uv(dir, scroll);

	float detail_fade = smoothstep(0.06, 0.55, dir.y);
	float noise = fbm_faded(uv, octaves, detail_fade);

	// Coverage remaps the threshold rather than scaling the noise, so clouds grow outward
	// from their own shapes instead of fading up uniformly.
	float threshold = mix(0.72, 0.18, cloud_coverage);
	// Soften the edge as detail drops away, so the horizon does not end in a hard scribble.
	float edge = mix(cloud_edge * 6.0, cloud_edge, detail_fade);
	return smoothstep(threshold, threshold + edge, noise);
}


void sky() {
	vec3 dir = normalize(EYEDIR);
	float height = clamp(dir.y, -1.0, 1.0);

	// --- banded sky gradient ---
	float gradient = pow(clamp(height, 0.0, 1.0), 1.0 / horizon_falloff);
	float banded_gradient = cel_quantize(gradient, sky_bands, 0.01);
	vec3 sky_color = mix(horizon_color, zenith_color, banded_gradient);

	// Below the horizon the dome should not keep brightening, or the skyline glows through
	// the sea. Step down to a darker tone instead.
	float below = smoothstep(0.0, -0.15, height);
	sky_color = mix(sky_color, below_horizon_color, below);

	// --- sun ---
	vec3 sun_dir = normalize(-LIGHT0_DIRECTION);
	float sun_dot = dot(dir, sun_dir);
	float sun_angle = acos(clamp(sun_dot, -1.0, 1.0));

	// Banded halo. Quantising it is what stops it reading as a soft bloom.
	//
	// Faded towards the horizon as well as away from the sun. A wide halo on a low sun
	// otherwise spills its tint along the whole skyline, and because the cloud layer also
	// fades out there nothing covers it — the result is a bright band sitting between the
	// clouds and the sea, which reads as a rendering error rather than as light.
	float glow = 1.0 - clamp(sun_angle / max(sun_glow_size, 0.0001), 0.0, 1.0);
	glow = cel_quantize(glow, sun_glow_bands, 0.02);
	glow *= smoothstep(0.0, 0.18, height);
	sky_color = mix(sky_color, sun_glow_color, glow * 0.65);

	// Solid disc with a single-pixel-ish edge, drawn only when the light is on.
	if (LIGHT0_ENABLED) {
		float disc = 1.0 - smoothstep(sun_size, sun_size + 0.004, sun_angle);
		sky_color = mix(sky_color, sun_color * sun_intensity, disc);
	}

	// --- clouds ---
	// Skipped entirely below the horizon: the cloud plane projection is only meaningful
	// above it, and the ocean covers that half of the dome anyway.
	if (height > 0.0) {
		float scroll = weather_time * cloud_speed;
		float density = cloud_density(dir, scroll, cloud_octaves);

		// A second faster layer adds the churn of a storm front. Costs nothing when off.
		if (storm_layer_strength > 0.001) {
			float storm = cloud_density(dir, scroll * 2.3 + 11.0, max(cloud_octaves - 1, 1));
			density = max(density, storm * storm_layer_strength);
		}

		// Fade the layer out towards the skyline so the compressed, unreadable end of the
		// projection never resolves into visible detail.
		density *= smoothstep(0.0, cloud_horizon_fade + 0.001, height);

		if (density > 0.001) {
			// Light the cloud from the sun using the noise gradient as a stand-in normal.
			// Sampling the field slightly toward the sun and comparing tells us which side
			// of a billow we are on, which is enough to place a lit rim and a shadow side
			// without any actual cloud geometry.
			vec2 sun_offset = normalize(sun_dir.xz + vec2(0.0001)) * 0.06;
			vec2 uv = cloud_plane_uv(dir, scroll);
			float toward_sun = fbm(uv + sun_offset, cloud_octaves);
			float here = fbm(uv, cloud_octaves);
			float lit = clamp((here - toward_sun) * 6.0 + cloud_light_wrap, 0.0, 1.0);

			// Three flat tones: lit rim, body, shadowed underside.
			float band = cel_quantize(lit, 3, 0.02);
			vec3 cloud_color = mix(cloud_shadow_color, cloud_mid_color, smoothstep(0.0, 0.5, band));
			cloud_color = mix(cloud_color, cloud_lit_color, smoothstep(0.5, 1.0, band));

			// Storm skies get darker bases: the thicker the cloud, the less light through.
			if (cloud_base_darkening > 0.001) {
				float thickness = cel_quantize(here, 3, 0.02);
				cloud_color *= mix(1.0, 1.0 - cloud_base_darkening, thickness);
			}

			sky_color = mix(sky_color, cloud_color, density);
		}
	}

	COLOR = sky_color;
}

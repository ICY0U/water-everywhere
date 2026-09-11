// Cel-shaded ocean.
//
// Waves are physically modelled: a spectrum of Gerstner (trochoidal) waves, which are the
// standard analytic solution for deep-water gravity waves. Each wave obeys the deep-water
// dispersion relation w = sqrt(g*k), so wave speed follows from wavelength rather than
// being hand-tuned, and horizontal displacement is capped across the spectrum so the
// surface can never self-intersect.
//
// The spectrum ITSELF is derived on the CPU from wind speed (see wave_field.gd) and pushed
// here as peak amplitude / peak wavelength. This shader is told the answer rather than
// recomputing the Pierson-Moskowitz maths, so the two can never disagree.
//
// The surface is then SHADED as cel: lighting is quantised into hard bands, foam is a crisp
// ink threshold, and depth absorption is stepped rather than continuous.
//
// The material this shader is used with must sit at a NEGATIVE render_priority. The surface
// is transparent-queued (it writes ALPHA so it can read the screen behind it), and Godot
// sorts transparent surfaces by object origin — but the ocean's rings are re-centred on the
// camera every frame, so their origin is always the nearest of anything on screen and they
// are drawn last, over every other transparent object. Anything floating in the sea then
// vanishes under the water it is floating on. Solid props avoid this by staying opaque; the
// priority covers the rest.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_disabled;

// ---------------------------------------------------------------------------
// Wave spectrum. Every value here is derived in wave_field.gd; see apply_to_material().
// ---------------------------------------------------------------------------
group_uniforms Waves;
uniform float peak_amplitude : hint_range(0.0, 8.0) = 0.51;
uniform float peak_wavelength : hint_range(1.0, 400.0) = 41.6;
// Per-octave scaling of both amplitude and wavelength, which holds steepness constant.
uniform float octave_ratio : hint_range(0.4, 0.95) = 0.74;
// Horizontal displacement as a fraction of vertical amplitude. 1.0 is an exact trochoid.
uniform float wave_chop : hint_range(0.0, 1.0) = 0.72;
uniform float wind_angle : hint_range(0.0, 360.0) = 45.0;
uniform float wind_spread : hint_range(0.0, 90.0) = 42.0;
uniform float wave_speed : hint_range(0.0, 3.0) = 1.0;
// Summed amplitude of the spectrum, used to normalise crest height into 0..1.
uniform float wave_total_amplitude : hint_range(0.01, 40.0) = 1.79;
group_uniforms;

group_uniforms Detail;
uniform sampler2D detail_normals : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_scale : hint_range(0.005, 0.5) = 0.055;
uniform float detail_strength : hint_range(0.0, 2.0) = 0.55;
uniform float detail_speed : hint_range(0.0, 0.5) = 0.045;
// Distance range over which the fine ripple normals fade to flat.
uniform float detail_fade_start : hint_range(1.0, 500.0) = 40.0;
uniform float detail_fade_end : hint_range(2.0, 2000.0) = 260.0;
group_uniforms;

// ---------------------------------------------------------------------------
// Cel shading
// ---------------------------------------------------------------------------
group_uniforms Cel;
// Number of hard lighting bands. This is what makes it read as cel rather than PBR.
uniform int light_bands : hint_range(2, 6) = 3;
// 0 = hard terminator (true cel), higher = softer edge to fight aliasing at distance.
uniform float band_softness : hint_range(0.0, 0.25) = 0.02;
uniform float shadow_lift : hint_range(0.0, 1.0) = 0.42;
// Where the cast-shadow edge falls. See cel_shadow() for why this is thresholded at all.
uniform float shadow_threshold : hint_range(0.0, 1.0) = 0.22;
uniform float shadow_edge_softness : hint_range(0.001, 0.2) = 0.03;
group_uniforms;

group_uniforms Colors;
uniform vec3 color_shallow : source_color = vec3(0.216, 0.678, 0.706);
uniform vec3 color_mid : source_color = vec3(0.075, 0.400, 0.573);
uniform vec3 color_deep : source_color = vec3(0.024, 0.157, 0.318);
uniform vec3 color_sky_tint : source_color = vec3(0.541, 0.784, 0.882);
// Depth (in metres) at which each color band takes over.
uniform float depth_band_1 : hint_range(0.1, 20.0) = 1.6;
uniform float depth_band_2 : hint_range(0.1, 40.0) = 7.0;
// How many hard colour steps the depth gradient is broken into.
uniform int depth_bands : hint_range(2, 8) = 4;
// How much darker the steeply-sloped faces of a wave get. Drives the banded facets.
uniform float wave_shade_strength : hint_range(0.0, 0.8) = 0.28;
// World-space direction TOWARD the sun. Set from the scene so the banding lines up with
// the DirectionalLight3D that is actually lighting the water.
uniform vec3 sun_direction = vec3(0.5, 0.7, 0.5);
// Hard colour steps from wave trough to crest. This is the most visible cel cue.
uniform int height_bands : hint_range(2, 8) = 4;
// How far the lit bands shift toward the shallow colour. Hue separation, not just value.
uniform float wave_band_tint : hint_range(0.0, 1.0) = 0.45;
group_uniforms;

// ---------------------------------------------------------------------------
// Subsurface scattering: sunlight that has passed THROUGH a thin crest.
// ---------------------------------------------------------------------------
group_uniforms Translucency;
uniform vec3 color_subsurface : source_color = vec3(0.42, 0.92, 0.72);
// How sharply the effect is confined to looking into the sun.
uniform float subsurface_power : hint_range(1.0, 16.0) = 4.0;
uniform float subsurface_strength : hint_range(0.0, 2.0) = 0.85;
// Crest height (0..1 above the mean) at which the glow starts and where it saturates.
uniform float subsurface_rise : hint_range(0.0, 1.0) = 0.30;
group_uniforms;

// ---------------------------------------------------------------------------
// Foam.
//
// Foam is NOT a height threshold. It is sourced from where the surface is physically
// breaking — the horizontal Jacobian of the wave field — and, near the viewer, from a
// persistent simulation (foam_sim.gdshader) that also carries object wakes. Height
// thresholds put foam on a contour line of constant elevation, which reads as a thin
// stroke drawn across the water rather than as anything breaking.
// ---------------------------------------------------------------------------
group_uniforms Foam;
uniform vec3 foam_color : source_color = vec3(0.98, 0.99, 1.0);
// Colour of the lacy outer fringe and of the bubbles inside the bright core.
uniform vec3 foam_edge_color : source_color = vec3(0.76, 0.85, 0.90);
// Surface compression at which water starts piling into foam. 1.0 is undisturbed water,
// so this must sit below 1; the further below, the rarer whitecaps become.
uniform float whitecap_threshold : hint_range(0.0, 1.0) = 0.80;
// Range of compression below the threshold over which foam reaches full strength.
uniform float whitecap_range : hint_range(0.01, 1.0) = 0.30;
// Where the lacy fringe and the solid core cut in, after noise has broken the field up.
uniform float foam_edge_level : hint_range(0.0, 1.0) = 0.28;
uniform float foam_core_level : hint_range(0.0, 1.0) = 0.60;
uniform float foam_level_softness : hint_range(0.001, 0.3) = 0.04;
uniform float foam_noise_scale : hint_range(0.01, 2.0) = 0.55;
// How far foam clumps are stretched along the wind. 1 is round, lower is more streaked.
uniform float foam_streak_stretch : hint_range(0.05, 1.0) = 0.38;
// Density of the dark speckle inside the bright core, which reads as bubbles.
uniform float foam_bubble_amount : hint_range(0.0, 1.0) = 0.45;
group_uniforms;

// ---------------------------------------------------------------------------
// Persistent foam simulation, rendered into a world-space texture around the viewer.
// R = actively breaking foam, G = the residue it leaves behind.
// ---------------------------------------------------------------------------
group_uniforms FoamMap;
uniform sampler2D foam_map : hint_default_black, filter_linear, repeat_disable;
uniform vec2 foam_map_center = vec2(0.0);
// Half-width of the area the map covers, in metres.
uniform float foam_map_extent : hint_range(1.0, 1000.0) = 96.0;
// 0 while no simulation is attached, which falls back to the analytic whitecaps alone.
uniform float foam_map_strength : hint_range(0.0, 1.0) = 0.0;
group_uniforms;

group_uniforms Surface;
uniform vec3 specular_color : source_color = vec3(1.0, 0.988, 0.925);
uniform float specular_size : hint_range(0.5, 256.0) = 48.0;
uniform float specular_strength : hint_range(0.0, 4.0) = 1.4;
// Cut-off for the hard glint. Near 1.0 keeps it a tight sparkle; lower floods the
// surface with white along the whole sun-reflection path.
uniform float specular_threshold : hint_range(0.5, 0.9999) = 0.995;
// How far the glitter noise is allowed to lower that cut-off, breaking the sun's path
// into individual sparks instead of one continuous sheet.
uniform float specular_glitter : hint_range(0.0, 0.2) = 0.06;
uniform float fresnel_power : hint_range(0.5, 8.0) = 4.2;
uniform float fresnel_strength : hint_range(0.0, 1.0) = 0.62;
uniform float refraction_strength : hint_range(0.0, 0.2) = 0.028;
// Assumed water depth where nothing is rendered behind the surface (open sea).
uniform float open_ocean_depth : hint_range(1.0, 200.0) = 25.0;
// How rough the water is to the renderer. High values stop the sky reflection from
// washing the cel colour bands out; low values give a photoreal mirror.
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.62;
group_uniforms;

// ---------------------------------------------------------------------------
// Objects in the water. Filled by ocean.gd from whatever reported contact this frame.
// ---------------------------------------------------------------------------
group_uniforms Contacts;
// xyz = world position of the contact, w = its radius in metres.
uniform vec4 contacts[8];
// xyz = world velocity, w = how submerged the object is (0..1).
uniform vec4 contact_motion[8];
// xy = unit heading through the water, w = speed along it in m/s. Zero when not under way.
uniform vec4 contact_wake[8];
uniform int contact_count : hint_range(0, 8) = 0;
// Metres the surface is pushed down under a fully submerged contact.
uniform float contact_depth : hint_range(0.0, 4.0) = 0.55;
// Speed at which the wake reaches full strength, in m/s.
uniform float wake_full_speed : hint_range(0.1, 20.0) = 4.0;
// How far behind the object the wake persists, in object radii.
uniform float wake_length : hint_range(1.0, 60.0) = 22.0;
// Height of the bow wave heaped up in front of a moving object, in metres.
uniform float wake_bow_height : hint_range(0.0, 2.0) = 0.35;
// Height of the divergent arms of the V, in metres.
uniform float wake_arm_height : hint_range(0.0, 2.0) = 0.22;
// Wavelength of the transverse waves trapped inside the V, in metres.
uniform float wake_transverse_length : hint_range(0.5, 30.0) = 6.0;
group_uniforms;

// Wave clock, driven from ocean.gd rather than the built-in TIME.
//
// TIME and the CPU's accumulated time can drift apart (TIME keeps running while the tree
// is paused in some configurations, and neither is guaranteed to start at the same
// instant). Buoyancy, foam and camera queries evaluate the same spectrum on the CPU, so
// every side must read one clock or floating objects sit at the wrong height.
uniform float wave_time = 0.0;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;

varying vec3 world_pos;
varying float crest_amount;
// The macro wave normal in WORLD space. NORMAL is converted to view space before
// fragment() runs, so anything comparing against world-space vectors (the camera
// direction, for fresnel) must use this instead.
varying vec3 wave_normal_world;
// Horizontal compression of the wave field: 1 is undisturbed, below 1 is water piling up.
// This is where real waves break, and it is what sources foam.
varying float surface_compression;
// Written in fragment(), read in light(): high-frequency mask that breaks the sun glint
// into sparks.
varying float glitter;

const float GRAVITY = 9.81;
const int WAVE_COUNT = 8;

// Mirrored exactly from wave_field.gd. A hash evaluated in both languages would not be
// guaranteed to agree bit for bit, so the offsets are written out instead.
const float OCTAVE_DIRECTION_OFFSETS[8] = float[8](
	0.0, 0.62, -0.41, 0.87, -0.73, 0.29, -0.95, 0.53);
const float OCTAVE_PHASES[8] = float[8](
	0.0, 2.31, 5.02, 1.17, 3.94, 0.58, 4.61, 2.87);
const float LONGEST_WAVE_SPREAD = 0.35;

// Returns the unit travel direction of one octave. Mirrored from WaveField.
vec2 octave_direction(int octave) {
	float shortness = float(octave) / float(WAVE_COUNT - 1);
	float narrowing = LONGEST_WAVE_SPREAD + (1.0 - LONGEST_WAVE_SPREAD) * shortness;
	float angle = radians(wind_angle + wind_spread * OCTAVE_DIRECTION_OFFSETS[octave] * narrowing);
	return vec2(cos(angle), sin(angle));
}

// Sums the wave spectrum. Mirrored exactly in wave_field.gd.
//
// `compression` is the determinant of the horizontal displacement Jacobian, which falls
// out of the same tangent/binormal accumulation the normal needs, so it costs nothing.
vec3 sample_waves(
		vec2 pos, float t, out vec3 normal, out float height_norm, out float compression) {
	vec3 displacement = vec3(0.0);
	vec3 tangent = vec3(1.0, 0.0, 0.0);
	vec3 binormal = vec3(0.0, 0.0, 1.0);

	float amp = peak_amplitude;
	float len = peak_wavelength;
	float scaled_time = t * wave_speed;

	for (int i = 0; i < WAVE_COUNT; i++) {
		vec2 dir = octave_direction(i);
		float k = 6.28318530718 / max(len, 0.0001);  // wave number
		float c = sqrt(GRAVITY / k);                 // deep-water phase speed
		float f = k * (dot(dir, pos) - c * scaled_time) + OCTAVE_PHASES[i];
		float cos_f = cos(f);
		float sin_f = sin(f);

		float slope = k * amp;
		float lateral_slope = wave_chop * slope;
		float lateral = wave_chop * amp;

		displacement += vec3(lateral * dir.x * cos_f, amp * sin_f, lateral * dir.y * cos_f);
		tangent += vec3(
			-lateral_slope * dir.x * dir.x * sin_f,
			dir.x * slope * cos_f,
			-lateral_slope * dir.x * dir.y * sin_f);
		binormal += vec3(
			-lateral_slope * dir.x * dir.y * sin_f,
			dir.y * slope * cos_f,
			-lateral_slope * dir.y * dir.y * sin_f);

		amp *= octave_ratio;
		len *= octave_ratio;
	}

	normal = normalize(cross(binormal, tangent));
	compression = tangent.x * binormal.z - tangent.z * binormal.x;
	height_norm = clamp(displacement.y / max(wave_total_amplitude, 0.0001) * 0.5 + 0.5, 0.0, 1.0);
	return displacement;
}

// Vertical displacement contributed by objects sitting in the water.
//
// Two regimes, because a hull at anchor and a hull under way disturb water in completely
// different shapes:
//
//   * STATIONARY - a symmetric hollow with a raised rim. The object displaces water
//     straight down and it heaps up around the waterline.
//   * UNDER WAY - a Kelvin wake. Everything the object displaces is left BEHIND it, in the
//     V that trails every ship on deep water.
//
// The two are blended by speed, so an object accelerating from rest grows its wake rather
// than switching to one.
float contact_offset(vec2 pos) {
	float offset = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= contact_count) {
			break;
		}
		vec4 contact = contacts[i];
		float radius = max(contact.w, 0.001);
		vec2 to_point = pos - contact.xz;
		float t = length(to_point) / radius;
		float submersion = contact_motion[i].w;

		// --- the hollow the hull sits in, always present ---
		float hollow = exp(-t * t * 2.0);
		float rim = exp(-(t - 1.2) * (t - 1.2) * 6.0) * 0.45;
		float still = rim - hollow;

		// --- the wake it drags behind, only when moving relative to the water ---
		vec2 heading = contact_wake[i].xy;
		float speed = contact_wake[i].w;
		float moving = clamp(speed / max(wake_full_speed, 0.001), 0.0, 1.0);
		float wake = 0.0;

		if (moving > 0.001) {
			// Object-local frame: +along is the way it is going, across is to port/starboard.
			vec2 side = vec2(-heading.y, heading.x);
			float along = dot(to_point, heading) / radius;
			float across = abs(dot(to_point, side)) / radius;

			// Astern is negative `along`. Everything below is written in terms of how far
			// BEHIND the object we are, which is where a wake lives.
			float behind = -along;

			// The Kelvin angle: 19.47 degrees, and famously INDEPENDENT of speed - it falls
			// out of deep-water dispersion, where group velocity is half phase velocity.
			// tan(19.47 deg) = 0.35355, so the arms open at that rate with distance astern.
			const float KELVIN_TAN = 0.35355;
			float arm_center = behind * KELVIN_TAN;

			// Fade along the wake's length, so it dissolves astern instead of running forever.
			float reach = clamp(1.0 - behind / max(wake_length, 0.001), 0.0, 1.0);
			float trailing = step(0.0, behind) * reach * reach;

			// The two divergent arms: crests riding along the edge of the V.
			//
			// Squared by multiplication, NOT by pow(). GLSL leaves pow(x, y) undefined for
			// negative x, and real drivers return NaN — which `across - arm_center` is for
			// every point inside the V. A NaN survives multiplication by zero, so none of the
			// masks below can contain it: it reaches the vertex position and every triangle
			// touching it is discarded, erasing a half-plane of ocean rather than presenting
			// as anything shader-shaped.
			float arm_offset = (across - arm_center) * 1.6;
			float arm = exp(-arm_offset * arm_offset);
			// Feathered so the arms are strongest near the object and thin out astern.
			wake += arm * trailing * wake_arm_height;

			// Transverse waves: the ripples trapped INSIDE the V, perpendicular to travel.
			// These are what make a wake read as water rather than as two painted lines.
			float inside = 1.0 - smoothstep(0.0, 1.0, across / max(arm_center, 0.001));
			float phase = behind * radius * 6.28318530718 / max(wake_transverse_length, 0.001);
			wake += cos(phase) * inside * trailing * wake_arm_height * 0.6;

			// The bow wave: water heaped up AHEAD of the object, which is what a hull pushing
			// through water actually does.
			float ahead = clamp(along, 0.0, 4.0);
			// Squared by multiplication for the same reason as the arms above: `ahead - 0.9`
			// is negative across the whole half-plane behind the bow line.
			float bow_offset = (ahead - 0.9) * 1.4;
			float bow = exp(-bow_offset * bow_offset) * exp(-across * across * 0.8);
			wake += bow * wake_bow_height;
		}

		// Blend the still hollow into the moving wake. The hollow never fully leaves - a
		// moving hull still sits in a depression - so it is only attenuated, not replaced.
		offset += (still * (1.0 - moving * 0.45) + wake * moving) * submersion;
	}
	return offset * contact_depth;
}

// Cheap value noise for breaking up foam edges.
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

// Quantise a 0..1 value into hard bands. The heart of the cel look.
//
// `softness` is the half-width of the blend across a band edge, measured in band units.
// It MUST stay below 0.5 or the smoothstep bounds cross over (lo > hi), which makes
// smoothstep return a smooth ramp - or a constant 1.0 - instead of a step. That failure
// silently turns the whole cel look back into a soft gradient, so clamp it here rather
// than trusting the caller.
float cel_quantize(float v, int bands, float softness) {
	float fb = float(bands);
	float scaled = clamp(v, 0.0, 1.0) * fb;
	float lower = floor(scaled);
	float frac_part = scaled - lower;
	float half_width = clamp(softness * fb, 0.0005, 0.49);
	float edge = smoothstep(0.5 - half_width, 0.5 + half_width, frac_part);
	return clamp((lower + edge) / fb, 0.0, 1.0);
}

// Collapses the shadow map's soft penumbra back to a hard cel edge.
//
// ATTENUATION must NOT be used raw here. Godot's soft shadows (PCSS, enabled by
// light_angular_distance, and the soft_shadow_filter_quality project setting) are
// stochastic: they sample the shadow map through a dither pattern, so ATTENUATION arrives
// as noise around the true value rather than as a clean mask. Multiplying quantised
// lighting by that noise is what turns a penumbra into flickering speckle - the band edge
// lands mid-dither, so neighbouring pixels snap to different bands.
//
// Thresholding first throws the dither away and restores the ink-line terminator cel
// shading wants. It also means the expensive soft-shadow filtering is stylistically
// irrelevant here, so shadow quality can be lowered for performance without changing the
// look.
//
// The threshold is deliberately narrow rather than a bare step(): a hair of width keeps
// the edge from aliasing into stair-steps at distance, the same reason band_softness
// exists.
float cel_shadow(float attenuation) {
	return smoothstep(
		shadow_threshold - shadow_edge_softness,
		shadow_threshold + shadow_edge_softness,
		attenuation);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 wave_normal;
	float hn;
	float compression;
	vec3 disp = sample_waves(world_pos.xz, wave_time, wave_normal, hn, compression);

	world_pos += disp;
	// Contacts are applied AFTER the wave displacement, against the position the water has
	// actually been carried to. Applying them to the undisplaced column would make the
	// hollow under an object slide about as the wave passes through it.
	disp.y += contact_offset(world_pos.xz);

	VERTEX += (inverse(MODEL_MATRIX) * vec4(disp, 0.0)).xyz;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	NORMAL = wave_normal;
	wave_normal_world = normalize((MODEL_MATRIX * vec4(wave_normal, 0.0)).xyz);
	crest_amount = hn;
	surface_compression = compression;
}

void fragment() {
	// --- surface normal: analytic wave normal + tiled detail normal map ---
	// Work in WORLD space here. NORMAL has already been converted to view space by the
	// time fragment() runs, so perturbing it with world-space XZ detail vectors (as the
	// blend below does) would mix two different coordinate frames.
	vec3 n = normalize(wave_normal_world);
	vec2 duv = world_pos.xz * detail_scale;
	vec2 drift_a = vec2(wave_time * detail_speed, wave_time * detail_speed * 0.6);
	vec2 drift_b = vec2(wave_time * detail_speed * 0.8, -wave_time * detail_speed * 0.4);
	vec3 dn1 = texture(detail_normals, duv + drift_a).xyz * 2.0 - 1.0;
	vec3 dn2 = texture(detail_normals, duv * 1.9 - drift_b).xyz * 2.0 - 1.0;
	vec3 detail = normalize(dn1 + dn2);
	// Fade the detail normals out with distance. Beyond a few tens of metres a single
	// pixel covers many ripples, so keeping them at full strength both aliases badly and
	// tilts normals toward grazing angles - which pushes the quantised fresnel into its
	// brightest band and washes the ocean out to white.
	float view_dist = length(world_pos - CAMERA_POSITION_WORLD);
	float detail_fade = 1.0 - smoothstep(detail_fade_start, detail_fade_end, view_dist);
	n = normalize(n + vec3(detail.x, 0.0, detail.y) * detail_strength * detail_fade);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	// --- water depth: how much water sits between this pixel and whatever is behind it ---
	// VERTEX is the view-space position of the water surface, so its distance from the
	// camera is -VERTEX.z (view space looks down -Z).
	//
	// Godot uses a reversed-Z depth buffer: near = 1.0, far = 0.0. So a raw depth of ~0
	// means "nothing was drawn here" - open ocean with only sky behind it. That is the
	// common case out at sea, and it must NOT be treated as infinitely deep water, or the
	// whole surface saturates to the deep colour and the horizon disappears.
	float raw_depth = texture(depth_tex, SCREEN_UV).r;
	float surface_dist = -VERTEX.z;
	float water_depth;

	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_pos.xyz /= view_pos.w;
	float scene_dist = -view_pos.z;

	// Treat anything at/behind the far plane, or level with the water itself, as open
	// sea. Without this the surface reads its OWN depth back and "refracts" the sky over
	// the whole ocean, washing the cel colours out to white.
	bool open_sea = raw_depth < 0.0000001 || scene_dist <= surface_dist + 0.01;
	water_depth = open_sea ? open_ocean_depth : max(scene_dist - surface_dist, 0.0);

	// --- stepped depth colour (cel version of Beer's law absorption) ---
	// Absorption is physically a smooth exponential; quantising it into hard steps is
	// what turns the depth gradient into painted colour bands.
	float depth_t = clamp(water_depth / max(depth_band_2, 0.0001), 0.0, 1.0);
	depth_t = cel_quantize(depth_t, depth_bands, band_softness);
	float d1 = smoothstep(0.0, depth_band_1 / max(depth_band_2, 0.0001), depth_t);
	float d2 = smoothstep(depth_band_1 / max(depth_band_2, 0.0001), 1.0, depth_t);
	vec3 water_col = mix(color_shallow, color_mid, d1);
	water_col = mix(water_col, color_deep, d2);

	// Banded shading baked into ALBEDO rather than left to light().
	//
	// light() only contributes DIFFUSE_LIGHT, which the renderer sums with ambient and
	// then tonemaps, so hard steps applied there get diluted back into a smooth gradient.
	// Quantising the surface colour here makes the bands survive that.
	//
	// The band is driven by wave HEIGHT, not by the surface normal. Normals vary smoothly
	// and slowly across a swell, so quantising them yields bands far wider than a single
	// wave - invisible at any normal viewing distance. Height changes sharply from trough
	// to crest, so height bands trace the wave shape the way a painted ocean is drawn.
	float band_h = cel_quantize(crest_amount, height_bands, band_softness);
	// Tilt toward the sun still modulates which side of a wave is the lit one.
	vec3 to_sun = normalize(sun_direction);
	float sun_facing = clamp(dot(wave_normal_world, to_sun), 0.0, 1.0);
	float lit_side = cel_quantize(sun_facing, light_bands, band_softness);
	float shade = clamp(band_h * 0.7 + lit_side * 0.3, 0.0, 1.0);

	// Shift HUE as well as brightness between bands. Multiplying a single colour only
	// darkens it, which the eye reads as soft shading; stepping between distinct colours
	// is what makes each band register as a separate painted region.
	vec3 band_dark = water_col * (1.0 - wave_shade_strength);
	vec3 band_light = mix(water_col, color_shallow, wave_band_tint);
	water_col = mix(band_dark, band_light, shade);

	// --- refraction: offset the screen sample by the surface normal ---
	// Only meaningful when something is actually submerged behind the surface. Out on the
	// open sea the "background" is sky, and blending it in just greys the water out.
	vec3 base = water_col;
	if (!open_sea) {
		vec2 refract_uv = SCREEN_UV + n.xz * refraction_strength * clamp(water_depth, 0.0, 1.0);
		vec3 behind = texture(screen_tex, refract_uv).rgb;
		// Shallow water shows what's behind it; deep water is opaque.
		float opacity = clamp(smoothstep(0.0, depth_band_2 * 0.6, water_depth), 0.0, 1.0);
		base = mix(behind * mix(vec3(1.0), color_shallow, 0.45), water_col, opacity);
	}

	// --- fresnel: a subtle sky rim near the horizon ---
	// Deliberately NOT run through cel_quantize. That function REMAPS its input onto band
	// centres - an input of 0.05 lands in the first band and comes back as 1/bands - so
	// quantising here turns a faint grazing-angle reflection into a full band of sky tint
	// across the entire near field. Fresnel is a blend weight, not a lighting term; the
	// cel banding it feeds (ALBEDO, and the light() bands) is where the steps belong.
	//
	// It is also keyed to the macro wave normal rather than the rippled one: detail
	// normals tilt the surface toward grazing angles almost everywhere up close.
	vec3 world_view_dir = normalize(CAMERA_POSITION_WORLD - world_pos);
	float facing = clamp(dot(wave_normal_world, world_view_dir), 0.0, 1.0);
	float fres = pow(1.0 - facing, fresnel_power) * fresnel_strength;
	base = mix(base, color_sky_tint, clamp(fres, 0.0, 1.0));

	// --- subsurface scattering through thin crests ---
	// Sunlight entering the back of a wave and leaving toward the viewer is what gives real
	// water its green glow at the top of a swell. It only happens where the water is thin
	// (near the crest) and where the viewer is looking roughly into the sun.
	//
	// Thresholded into two hard steps rather than run through cel_quantize: this is a blend
	// weight, and quantising a blend weight lifts near-zero values into a full band.
	float above_mean = clamp((crest_amount - 0.5) * 2.0, 0.0, 1.0);
	float thin = smoothstep(subsurface_rise, 1.0, above_mean);
	float into_sun = clamp(-dot(world_view_dir, to_sun) * 0.5 + 0.5, 0.0, 1.0);
	float back_lit = pow(into_sun, subsurface_power);
	float sss_raw = back_lit * thin * subsurface_strength;
	float sss = (step(0.18, sss_raw) * 0.45 + step(0.42, sss_raw) * 0.55);
	base = mix(base, color_subsurface, clamp(sss, 0.0, 1.0));

	// --- foam ---
	// Two sources, blended by distance:
	//   * near the viewer, the persistent simulation (breaking foam in R, its residue in
	//     G), which carries wakes and remembers where waves have already broken;
	//   * beyond the simulated area, the analytic whitecap, which has no memory but costs
	//     nothing and keeps the horizon from being suspiciously clean.
	float analytic_break = clamp(
		(whitecap_threshold - surface_compression) / max(whitecap_range, 0.0001), 0.0, 1.0);

	vec2 foam_uv = (world_pos.xz - foam_map_center) / (2.0 * foam_map_extent) + 0.5;
	vec2 edge_fade = smoothstep(vec2(0.0), vec2(0.08), foam_uv)
		* (1.0 - smoothstep(vec2(0.92), vec2(1.0), foam_uv));
	float map_weight = foam_map_strength * edge_fade.x * edge_fade.y;
	vec2 simulated = texture(foam_map, clamp(foam_uv, vec2(0.0), vec2(1.0))).rg;

	float breaking = mix(analytic_break, simulated.r, map_weight);
	float residue = simulated.g * map_weight;

	// Tear the field up with noise. The simulation resolves foam only down to its texel
	// size, so on its own it reads as smooth white puddles; the shape of the edge - the
	// thing the eye actually uses to identify foam - has to be added here.
	//
	// The noise is sampled in WIND space with the along-wind axis squashed, because foam
	// does not tear isotropically: it is stretched into streaks by the same surface drift
	// that carries it, so the clumps have to elongate downwind. Three octaves rather than
	// two, because the finest one is what frays the boundary instead of merely warping it.
	float wind_rad = radians(wind_angle);
	vec2 wind_dir = vec2(cos(wind_rad), sin(wind_rad));
	vec2 wind_side = vec2(-wind_dir.y, wind_dir.x);
	vec2 wind_space = vec2(dot(world_pos.xz, wind_dir), dot(world_pos.xz, wind_side));
	vec2 fuv = vec2(wind_space.x * foam_streak_stretch, wind_space.y) * foam_noise_scale;
	vec2 crawl = vec2(-wave_time * 0.22, wave_time * 0.05);
	float texture_mask = value_noise(fuv + crawl) * 0.5
		+ value_noise(fuv * 2.3 - crawl * 0.6) * 0.32
		+ value_noise(fuv * 5.9 + crawl * 0.3) * 0.18;

	// Contrast the mask before it is used. Summed value noise is narrowly distributed
	// around 0.5, so multiplying by it only SHADES a foam patch - it almost never dips far
	// enough to cross the cut and actually remove any of it, which is why unshaped foam
	// stays a smooth white puddle no matter how much noise is layered on. Stretching the
	// middle of the distribution out to the full range is what turns it into holes.
	float torn = smoothstep(0.30, 0.70, texture_mask);
	float shaping = 0.15 + 1.5 * torn;
	float lace_field = max(breaking, residue) * shaping;
	float core_field = breaking * shaping;
	float lace = smoothstep(foam_edge_level, foam_edge_level + foam_level_softness, lace_field);
	float core = smoothstep(foam_core_level, foam_core_level + foam_level_softness, core_field);

	// Speckle the solid core so it reads as packed bubbles rather than as flat paint. Faded
	// out with the detail normals, for the same reason: at distance one pixel covers many
	// bubbles and their average is just a slightly darker white.
	float bubbles = value_noise(world_pos.xz * foam_noise_scale * 9.0 + crawl * 0.4);
	float bubble_mask = step(bubbles, foam_bubble_amount) * detail_fade;
	vec3 foam_paint = mix(foam_edge_color, foam_color, core);
	foam_paint = mix(foam_paint, foam_edge_color, bubble_mask * core * 0.55);

	float foam = clamp(lace, 0.0, 1.0);
	base = mix(base, foam_paint, foam);

	// Sun glitter mask, consumed by light(). Two scales of noise so the sparkles do not
	// tile into a visible grid, faded out with the detail normals for the same reason they
	// are: at distance a pixel covers many sparkles and the average is a white sheet.
	glitter = (value_noise(world_pos.xz * 3.7 + wave_time * 0.6)
		* value_noise(world_pos.xz * 1.3 - wave_time * 0.25)) * detail_fade;

	ALBEDO = base;
	// Cel water is a painted surface, not a mirror. A low ROUGHNESS here makes Godot
	// reflect the full-brightness HDRI sky across the whole ocean, which greys out the
	// colour bands - the exact effect that reads as "photoreal haze" instead of cel.
	// specular_disabled in render_mode removes Godot's GGX lobe and its sky reflection
	// entirely - that reflection is what greys a cel ocean out. The only highlight is the
	// hard glint drawn in light() below, which is the look we actually want.
	ROUGHNESS = mix(surface_roughness, 0.95, foam);
	METALLIC = 0.0;
	ALPHA = 1.0;
}

// Custom cel lighting. Replaces Godot's smooth PBR falloff with hard quantised bands.
void light() {
	vec3 nrm = normalize(NORMAL);
	vec3 ldir = normalize(LIGHT);
	float ndotl = dot(nrm, ldir);
	// Half-lambert keeps the unlit side coloured rather than black, then quantise.
	float wrapped = ndotl * 0.5 + 0.5;
	float banded = cel_quantize(wrapped, light_bands, band_softness);
	banded = mix(shadow_lift, 1.0, banded);

	float shadow = cel_shadow(ATTENUATION);

	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * shadow * banded;

	// Single hard specular blob rather than a soft GGX lobe.
	//
	// The threshold must sit near the TOP of pow()'s range, not the middle: pow(ndoth,
	// size) is already close to 1 across a wide arc of the surface, so cutting at 0.35
	// turns the sun's whole reflected path into a solid white sheet. Cutting just below
	// 1.0 keeps it a tight, sparkling glint - which is what reads as cel.
	//
	// The glitter mask lowers that cut-off locally, so instead of one continuous streak
	// the sun's path breaks into individual sparks that wink as the surface moves. That is
	// what real sun glitter is: a field of momentarily aligned facets.
	vec3 h = normalize(ldir + normalize(VIEW));
	float ndoth = max(dot(nrm, h), 0.0);
	float spec = pow(ndoth, specular_size);
	spec = step(specular_threshold - glitter * specular_glitter, spec);
	SPECULAR_LIGHT += specular_color * spec * specular_strength * shadow * LIGHT_COLOR;
}

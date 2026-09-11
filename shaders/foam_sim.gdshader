// Persistent foam simulation.
//
// Rendered into a world-space texture that follows the viewer (see foam_field.gd), one
// texel per patch of sea. Each frame the previous state is re-projected onto the new
// window, drifted, blurred and decayed, and then new foam is added from two sources:
//
//   * whitecaps, taken from where the wave field is physically breaking; and
//   * objects, from whatever reported contact with the water this frame.
//
// Foam behaving realistically is mostly about MEMORY. Real foam outlives the wave that
// made it: a crest breaks, throws white water, and leaves a streak that drifts downwind
// and dissolves over several seconds. A shader that derives foam from the current wave
// state alone can only ever draw foam that appears and vanishes with the crest, which is
// the tell that gives away most stylised water.
//
// R = actively breaking foam: bright, dense, short-lived.
// G = the residue it leaves behind: lacy, drifting, slow to fade.
shader_type canvas_item;
render_mode blend_disabled, unshaded;

// ---------------------------------------------------------------------------
// Simulation window
// ---------------------------------------------------------------------------
uniform sampler2D previous_map : hint_default_black, filter_linear, repeat_disable;
// Centre of the area covered, in world XZ, this frame and last frame.
uniform vec2 sim_center = vec2(0.0);
uniform vec2 previous_center = vec2(0.0);
// Half-width of the area covered, in metres.
uniform float sim_extent = 96.0;
uniform float sim_delta = 0.016;

// ---------------------------------------------------------------------------
// Wave spectrum. Identical uniform names to ocean.gdshader, so one WaveField drives both.
// ---------------------------------------------------------------------------
uniform float peak_amplitude : hint_range(0.0, 8.0) = 0.51;
uniform float peak_wavelength : hint_range(1.0, 400.0) = 41.6;
uniform float octave_ratio : hint_range(0.4, 0.95) = 0.74;
uniform float wave_chop : hint_range(0.0, 1.0) = 0.72;
uniform float wind_angle : hint_range(0.0, 360.0) = 45.0;
uniform float wind_spread : hint_range(0.0, 90.0) = 42.0;
uniform float wave_speed : hint_range(0.0, 3.0) = 1.0;
uniform float wave_time = 0.0;

// ---------------------------------------------------------------------------
// Foam behaviour
// ---------------------------------------------------------------------------
// Surface compression at which water starts piling into foam; 1.0 is undisturbed water.
uniform float whitecap_threshold : hint_range(0.0, 1.0) = 0.80;
uniform float whitecap_range : hint_range(0.01, 1.0) = 0.30;
// Fraction of the breaking foam that survives one second.
uniform float foam_decay : hint_range(0.0, 1.0) = 0.12;
// Fraction of the residue that survives one second. Higher means longer-lived streaks.
uniform float residue_decay : hint_range(0.0, 1.0) = 0.55;
// How much of the breaking foam is left behind as residue.
uniform float residue_gain : hint_range(0.0, 1.0) = 0.75;
// How far foam bleeds outward per second, in metres. Real foam spreads as it dissipates.
uniform float foam_spread : hint_range(0.0, 8.0) = 1.4;
// Surface drift, in metres per second. Stokes drift carries floating matter downwind at
// roughly 2% of the wind speed, which is what makes foam streaks line up with the wind.
uniform vec2 foam_drift = vec2(0.0);

// ---------------------------------------------------------------------------
// Objects in the water
// ---------------------------------------------------------------------------
// xyz = world position of the contact, w = its radius in metres.
uniform vec4 contacts[8];
// xyz = world velocity, w = how submerged the object is (0..1).
uniform vec4 contact_motion[8];
// xy = unit heading through the water, w = speed along it in m/s. Zero when not under way.
uniform vec4 contact_wake[8];
uniform int contact_count : hint_range(0, 8) = 0;
uniform float contact_foam : hint_range(0.0, 4.0) = 1.0;
// Speed at which an object's wake foam reaches full strength, in m/s.
uniform float wake_full_speed : hint_range(0.1, 20.0) = 4.0;
// How far behind a moving object foam is laid down, in object radii.
uniform float wake_length : hint_range(1.0, 60.0) = 22.0;

const float GRAVITY = 9.81;
const int WAVE_COUNT = 8;

// Mirrored exactly from wave_field.gd and ocean.gdshader.
const float OCTAVE_DIRECTION_OFFSETS[8] = float[8](
	0.0, 0.62, -0.41, 0.87, -0.73, 0.29, -0.95, 0.53);
const float OCTAVE_PHASES[8] = float[8](
	0.0, 2.31, 5.02, 1.17, 3.94, 0.58, 4.61, 2.87);
const float LONGEST_WAVE_SPREAD = 0.35;

vec2 octave_direction(int octave) {
	float shortness = float(octave) / float(WAVE_COUNT - 1);
	float narrowing = LONGEST_WAVE_SPREAD + (1.0 - LONGEST_WAVE_SPREAD) * shortness;
	float angle = radians(wind_angle + wind_spread * OCTAVE_DIRECTION_OFFSETS[octave] * narrowing);
	return vec2(cos(angle), sin(angle));
}

// Determinant of the horizontal displacement Jacobian.
//
// 1 is undisturbed water, above 1 is a trough stretching apart, and below 1 is water
// piling up against itself. Real waves break where this collapses toward 0, which makes it
// the physical criterion for a whitecap - as opposed to a height threshold, which merely
// marks a contour line of constant elevation.
float surface_compression(vec2 pos, float t) {
	// Only the horizontal terms of the tangent frame matter here.
	vec2 tangent_xz = vec2(1.0, 0.0);
	vec2 binormal_xz = vec2(0.0, 1.0);

	float amp = peak_amplitude;
	float len = peak_wavelength;
	float scaled_time = t * wave_speed;

	for (int i = 0; i < WAVE_COUNT; i++) {
		vec2 dir = octave_direction(i);
		float k = 6.28318530718 / max(len, 0.0001);
		float c = sqrt(GRAVITY / k);
		float f = k * (dot(dir, pos) - c * scaled_time) + OCTAVE_PHASES[i];
		float lateral_slope = wave_chop * k * amp * sin(f);

		tangent_xz += vec2(-lateral_slope * dir.x * dir.x, -lateral_slope * dir.x * dir.y);
		binormal_xz += vec2(-lateral_slope * dir.x * dir.y, -lateral_slope * dir.y * dir.y);

		amp *= octave_ratio;
		len *= octave_ratio;
	}

	return tangent_xz.x * binormal_xz.y - tangent_xz.y * binormal_xz.x;
}

// Foam thrown by objects sitting in or moving through the water.
//
// A stationary hull churns a ring at its own waterline. A moving one leaves that foam
// BEHIND it, along the arms of its Kelvin wake - which is the difference between a boat at
// anchor and a boat under way, and the thing a symmetric ring can never express.
//
// This deliberately mirrors the wake geometry in ocean.gdshader: foam has to sit on the
// crests the surface shader is actually raising, or the white lands next to the wave that
// made it.
float contact_source(vec2 pos) {
	float total = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= contact_count) {
			break;
		}
		vec4 contact = contacts[i];
		float radius = max(contact.w, 0.001);
		vec2 to_point = pos - contact.xz;
		float d = length(to_point) / radius;
		float submersion = contact_motion[i].w;

		// The churn directly under and around the hull, present whether moving or not.
		float ring = exp(-(d - 1.0) * (d - 1.0) * 5.0);
		float churn = exp(-d * d * 1.6) * 0.45;

		vec2 heading = contact_wake[i].xy;
		float speed = contact_wake[i].w;
		float moving = clamp(speed / max(wake_full_speed, 0.001), 0.0, 1.0);

		float wake = 0.0;
		if (moving > 0.001) {
			vec2 side = vec2(-heading.y, heading.x);
			float behind = -dot(to_point, heading) / radius;
			float across = abs(dot(to_point, side)) / radius;

			// Same 19.47 degree Kelvin angle the surface shader raises its arms at.
			const float KELVIN_TAN = 0.35355;
			float arm_center = behind * KELVIN_TAN;
			float reach = clamp(1.0 - behind / max(wake_length, 0.001), 0.0, 1.0);
			float trailing = step(0.0, behind) * reach;

			// Foam clings to the arms of the V, and fills the turbulent strip immediately
			// astern where the hull has just passed.
			// Squared by multiplication, not by pow(): GLSL leaves pow() undefined for a
			// negative base, and `across - arm_center` is negative everywhere inside the V.
			// The resulting NaN cannot be masked away, because NaN survives being multiplied
			// by zero.
			float arm_offset = (across - arm_center) * 1.9;
			float arms = exp(-arm_offset * arm_offset);
			float trail = exp(-across * across * 0.7) * exp(-behind * 0.12);
			wake = (arms * 0.85 + trail * 0.55) * trailing;
		}

		// Foam production scales with the work the object is doing on the water: a hull
		// under way whitens far more water than one merely bobbing.
		float effort = 0.30 + speed * 0.28;
		total += ((ring + churn) * (1.0 - moving * 0.5) + wake * moving) * submersion * effort;
	}
	return clamp(total * contact_foam, 0.0, 1.0);
}

// Samples the previous frame at a world position, returning zero outside the old window.
vec2 sample_previous(vec2 world) {
	vec2 uv = (world - previous_center) / (2.0 * sim_extent) + 0.5;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		return vec2(0.0);
	}
	return texture(previous_map, uv).rg;
}

void fragment() {
	vec2 world = sim_center + (UV - 0.5) * 2.0 * sim_extent;

	// Advect against the drift, then blur outward. Sampling four taps at the spread
	// distance is a coarse diffusion step, but foam genuinely does spread as it breaks up,
	// so the error is in the right direction.
	vec2 source_world = world - foam_drift * sim_delta;
	float reach = foam_spread * sim_delta;
	vec2 carried = sample_previous(source_world) * 0.4;
	carried += sample_previous(source_world + vec2(reach, 0.0)) * 0.15;
	carried += sample_previous(source_world - vec2(reach, 0.0)) * 0.15;
	carried += sample_previous(source_world + vec2(0.0, reach)) * 0.15;
	carried += sample_previous(source_world - vec2(0.0, reach)) * 0.15;

	// Exponential decay expressed as "fraction surviving one second", so the rate is
	// frame-rate independent and readable as a half-life rather than as a magic constant.
	float breaking = carried.r * pow(max(foam_decay, 0.0001), sim_delta);
	float residue = carried.g * pow(max(residue_decay, 0.0001), sim_delta);

	float compression = surface_compression(world, wave_time);
	float whitecap = clamp(
		(whitecap_threshold - compression) / max(whitecap_range, 0.0001), 0.0, 1.0);

	breaking = max(breaking, max(whitecap, contact_source(world)));
	// Residue records the high-water mark of the foam that has passed through, which is
	// what leaves a streak behind a crest and a wake behind an object.
	residue = max(residue, breaking * residue_gain);

	COLOR = vec4(clamp(breaking, 0.0, 1.0), clamp(residue, 0.0, 1.0), 0.0, 1.0);
}

// The Gerstner wave spectrum, for shaders that need to know where the water is without
// being the water: spray launched from breaking crests, rain falling onto the swell, and
// ripple rings riding on it.
//
// This is a mirror of sample_waves() in ocean.gdshader and of WaveField on the CPU, and it
// must stay one. Every uniform in the Waves group is written by
// WaveField.apply_to_material() under the same names the ocean uses, so a material that
// includes this file is kept in step by that one call; wave_time and sea_level are pushed
// from the Ocean node every frame. tools/verify_spray.gd evaluates this file on the GPU and
// compares the result against WaveField, so a drift between the two is caught rather than
// seen as droplets landing in mid-air.

group_uniforms Waves;
uniform float peak_amplitude : hint_range(0.0, 8.0) = 0.51;
uniform float peak_wavelength : hint_range(1.0, 400.0) = 41.6;
uniform float octave_ratio : hint_range(0.4, 0.95) = 0.74;
uniform float wave_chop : hint_range(0.0, 1.0) = 0.72;
uniform float wind_angle : hint_range(0.0, 360.0) = 45.0;
uniform float wind_spread : hint_range(0.0, 90.0) = 42.0;
uniform float wave_speed : hint_range(0.0, 3.0) = 1.0;
uniform float wave_total_amplitude : hint_range(0.01, 40.0) = 1.79;
// The Ocean's clock, pushed every frame. Never TIME: two clocks drift apart under
// Engine.time_scale and pausing, and particles would then land on a sea that is not drawn.
uniform float wave_time = 0.0;
// World height of the undisturbed surface: the Ocean node's global Y.
uniform float sea_level = 0.0;
group_uniforms;

const float WAVE_GRAVITY = 9.81;
const int WAVE_COUNT = 8;

// Mirrored exactly from wave_field.gd. A hash evaluated in both languages would not be
// guaranteed to agree bit for bit, so the offsets are written out instead.
const float WAVE_DIRECTION_OFFSETS[8] = float[8](
	0.0, 0.62, -0.41, 0.87, -0.73, 0.29, -0.95, 0.53);
const float WAVE_PHASES[8] = float[8](
	0.0, 2.31, 5.02, 1.17, 3.94, 0.58, 4.61, 2.87);
const float WAVE_LONGEST_SPREAD = 0.35;

// Fixed-point iterations used to undo horizontal displacement. Matches
// WaveField.SURFACE_POINT_ITERATIONS, so the GPU and CPU agree on where the surface is.
const int WAVE_INVERSION_ITERATIONS = 3;

// Returns the unit travel direction of one octave.
vec2 wave_octave_direction(int octave) {
	float shortness = float(octave) / float(WAVE_COUNT - 1);
	float narrowing = WAVE_LONGEST_SPREAD + (1.0 - WAVE_LONGEST_SPREAD) * shortness;
	float angle = radians(wind_angle + wind_spread * WAVE_DIRECTION_OFFSETS[octave] * narrowing);
	return vec2(cos(angle), sin(angle));
}

// Returns the displacement of the water that rests at `origin`.
//
// The cheap form, for when neither the normal nor the compression is needed.
vec3 wave_displacement(vec2 origin, float t) {
	vec3 displacement = vec3(0.0);
	float amp = peak_amplitude;
	float len = peak_wavelength;
	float scaled_time = t * wave_speed;

	for (int i = 0; i < WAVE_COUNT; i++) {
		vec2 dir = wave_octave_direction(i);
		float k = TAU / max(len, 0.0001);
		float c = sqrt(WAVE_GRAVITY / k);
		float phase = k * (dot(dir, origin) - c * scaled_time) + WAVE_PHASES[i];
		float lateral = wave_chop * amp;
		displacement += vec3(lateral * dir.x * cos(phase), amp * sin(phase), lateral * dir.y * cos(phase));
		amp *= octave_ratio;
		len *= octave_ratio;
	}
	return displacement;
}

// Returns the displacement at `origin`, with the unit surface normal there and the
// horizontal compression (the determinant of the displacement Jacobian).
//
// Compression is 1 on undisturbed water and falls below 1 where water piles up on the face
// of a crest. That is where a real wave breaks, and so where spray comes from.
vec3 wave_sample(vec2 origin, float t, out vec3 normal, out float compression) {
	vec3 displacement = vec3(0.0);
	vec3 tangent = vec3(1.0, 0.0, 0.0);
	vec3 binormal = vec3(0.0, 0.0, 1.0);
	float amp = peak_amplitude;
	float len = peak_wavelength;
	float scaled_time = t * wave_speed;

	for (int i = 0; i < WAVE_COUNT; i++) {
		vec2 dir = wave_octave_direction(i);
		float k = TAU / max(len, 0.0001);
		float c = sqrt(WAVE_GRAVITY / k);
		float phase = k * (dot(dir, origin) - c * scaled_time) + WAVE_PHASES[i];
		float cos_phase = cos(phase);
		float sin_phase = sin(phase);
		float slope = k * amp;
		float lateral_slope = wave_chop * slope;
		float lateral = wave_chop * amp;

		displacement += vec3(lateral * dir.x * cos_phase, amp * sin_phase, lateral * dir.y * cos_phase);
		tangent += vec3(
			-lateral_slope * dir.x * dir.x * sin_phase,
			dir.x * slope * cos_phase,
			-lateral_slope * dir.x * dir.y * sin_phase);
		binormal += vec3(
			-lateral_slope * dir.x * dir.y * sin_phase,
			dir.y * slope * cos_phase,
			-lateral_slope * dir.y * dir.y * sin_phase);

		amp *= octave_ratio;
		len *= octave_ratio;
	}

	normal = normalize(cross(binormal, tangent));
	compression = tangent.x * binormal.z - tangent.z * binormal.x;
	return displacement;
}

// Returns the velocity of the water that rests at `origin`, in metres per second.
//
// The exact time derivative of wave_displacement(), orbital motion included, so spray
// thrown off a crest leaves it carrying the crest's own forward speed.
vec3 wave_velocity(vec2 origin, float t) {
	vec3 velocity = vec3(0.0);
	float amp = peak_amplitude;
	float len = peak_wavelength;
	float scaled_time = t * wave_speed;

	for (int i = 0; i < WAVE_COUNT; i++) {
		vec2 dir = wave_octave_direction(i);
		float k = TAU / max(len, 0.0001);
		float c = sqrt(WAVE_GRAVITY / k);
		float phase = k * (dot(dir, origin) - c * scaled_time) + WAVE_PHASES[i];
		// d(phase)/dt, negated: the phase runs backwards as the wave travels forwards.
		float angular_rate = k * c * wave_speed;
		float lateral = wave_chop * amp;

		velocity += vec3(
			lateral * dir.x * sin(phase) * angular_rate,
			-amp * cos(phase) * angular_rate,
			lateral * dir.y * sin(phase) * angular_rate);

		amp *= octave_ratio;
		len *= octave_ratio;
	}
	return velocity;
}

// Returns the rest position whose displaced water sits above `world_xz`.
//
// Gerstner waves move water sideways, so the surface above a column was generated
// somewhere else. Walks back to that origin the same way WaveField.sample_surface_point()
// does.
vec2 wave_origin_below(vec2 world_xz, float t) {
	vec2 origin = world_xz;
	for (int i = 0; i < WAVE_INVERSION_ITERATIONS; i++) {
		origin += world_xz - (origin + wave_displacement(origin, t).xz);
	}
	return origin;
}

// Returns the world height of the water surface directly above `world_xz`.
float wave_surface_height(vec2 world_xz, float t) {
	return sea_level + wave_displacement(wave_origin_below(world_xz, t), t).y;
}

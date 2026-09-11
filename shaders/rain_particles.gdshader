// Rain falling onto the swell.
//
// Drops fill a column around the viewer from the sea up to a ceiling above whichever is
// higher, the viewer or the sea. They fall at a raindrop's terminal velocity, drifting with
// the wind, and each one that reaches the water leaves a ripple ring through the
// sub-emitter. Drops are started at random heights inside the column rather than all at
// the top, so the rain is already falling on the first frame instead of arriving as a front.
//
// Each drop is spawned upwind of where it will land, by the distance the wind carries it
// during its fall, so the patch of sea being rained on stays centred on the viewer however
// hard the wind blows.
//
// Godot rejects `return` inside start() and process(), so early exits are conditions.
//
// CUSTOM: x = random 0..1 for the draw shader, y = age 0..1, w = life in seconds.
//
// A drop needs a life of its own even though it normally dies by landing. When the rain
// stops, the emitter stops restarting slots, so anything still in the air at that moment
// would otherwise hang there for good — leaving streaks of rain falling through a scene
// that has been sunny for some time.
shader_type particles;

#include "res://shaders/gerstner_waves.gdshaderinc"
#include "res://shaders/particle_common.gdshaderinc"

group_uniforms Emission;
// Fraction of drops that fall. Set from the weather preset's rain intensity.
uniform float rain_amount : hint_range(0.0, 1.0) = 1.0;
// Radius of the rained-on patch of sea around the emitter, in metres.
uniform float rain_radius : hint_range(1.0, 200.0) = 45.0;
// How far above the viewer (or the sea, if higher) drops can appear, in metres.
uniform float rain_ceiling : hint_range(1.0, 200.0) = 22.0;
uniform vec3 viewer_position = vec3(0.0);
group_uniforms;

group_uniforms Fall;
// Terminal velocity of the drops, in m/s: minimum and maximum. Real raindrops of 1-4 mm
// fall at roughly 4-9 m/s; storm rain sits at the top of that range.
uniform vec2 fall_speed = vec2(7.0, 9.0);
// Wind speed ten metres above the surface, in m/s. Pushed from the WaveField.
uniform float wind_speed : hint_range(0.0, 40.0) = 10.0;
// How much of the wind the drops carry. A raindrop reaches the air's horizontal speed
// within a few metres of falling, so 1.0 is physical; lower is more upright rain.
uniform float wind_fraction : hint_range(0.0, 1.0) = 0.6;
// Drawn width of a drop, in metres.
uniform float drop_size : hint_range(0.001, 0.2) = 0.03;
group_uniforms;

group_uniforms Ripples;
uniform float ripple_max_distance : hint_range(0.0, 200.0) = 32.0;
// Ring radius range, in metres.
uniform vec2 ripple_radius = vec2(0.22, 0.45);
uniform float ripple_lifetime : hint_range(0.1, 4.0) = 0.7;
group_uniforms;

void start() {
	uint state = particle_seed(RANDOM_SEED, NUMBER);
	CUSTOM = vec4(particle_random(state), 0.0, 0.0, 0.0);
	ACTIVE = particle_random(state) < rain_amount;

	if (ACTIVE) {
		float heading = radians(wind_angle);
		vec2 drift = vec2(cos(heading), sin(heading)) * wind_speed * wind_fraction;
		float speed = mix(fall_speed.x, fall_speed.y, particle_random(state));

		float top = max(viewer_position.y, sea_level) + rain_ceiling;
		float height = mix(sea_level, top, particle_random(state));
		float fall_time = (height - sea_level) / speed;

		// Uniform over the disc: rain density does not fall off with distance the way spray's
		// search pattern does, because every patch of this sea is being rained on equally.
		float angle = TAU * particle_random(state);
		float radius = rain_radius * sqrt(particle_random(state));
		vec2 landing = EMISSION_TRANSFORM[3].xz + radius * vec2(cos(angle), sin(angle));
		vec2 spawn = landing - drift * fall_time;

		VELOCITY = vec3(drift.x, -speed, drift.y);
		TRANSFORM = particle_streak_transform(
			vec3(spawn.x, height, spawn.y), VELOCITY, drop_size);
		// Long enough to reach the water from where it started, with room for the swell.
		CUSTOM.w = fall_time + 2.0;
	}
}

void process() {
	float age = CUSTOM.y + DELTA / max(CUSTOM.w, 0.001);
	if (age >= 1.0) {
		ACTIVE = false;
	}

	if (ACTIVE) {
		CUSTOM.y = age;
		vec3 position = TRANSFORM[3].xyz;
		bool landed = false;
		// Nothing above the tallest possible crest can be under water.
		if (position.y < sea_level + wave_total_amplitude) {
			float surface = wave_surface_height(position.xz, wave_time);
			landed = position.y <= surface;
			if (landed && distance(position, viewer_position) < ripple_max_distance) {
				uint state = particle_hash(floatBitsToUint(CUSTOM.x) ^ 7919u);
				mat4 landing = mat4(1.0);
				landing[3] = vec4(position.x, surface, position.z, 1.0);
				emit_subparticle(
					landing,
					vec3(0.0),
					vec4(1.0),
					vec4(
						CUSTOM.x,
						0.0,
						mix(ripple_radius.x, ripple_radius.y, particle_random(state)),
						ripple_lifetime),
					FLAG_EMIT_POSITION | FLAG_EMIT_CUSTOM);
			}
		}

		if (landed) {
			ACTIVE = false;
		} else {
			TRANSFORM = particle_streak_transform(position, VELOCITY, drop_size);
		}
	}
}

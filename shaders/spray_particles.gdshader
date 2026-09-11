// Spray thrown off breaking crests, and at gale force the spindrift torn from them.
//
// Particles are not emitted from a shape. On each restart a particle examines a few random
// points of sea around the viewer and launches from whichever is breaking hardest — measured
// by the same horizontal compression that sources the foam — or stays dead if none is. So
// spray only ever leaves crests that are physically breaking, and a calm sea emits nothing
// without any separate switch.
//
// Examining several candidates rather than one is what keeps the budget useful. Scattering
// particles evenly and culling those that land on unbroken water (the usual approach) wastes
// most of them, so raising the count barely changes what is seen. Keeping the best of a few
// candidates concentrates the same budget on the crests.
//
// Once airborne a droplet is ballistic: gravity, plus drag toward the wind that grows as the
// droplet shrinks, so fine spindrift streams downwind while heavy spray arcs and falls back.
// It lands on the real wave surface and hands a ripple ring to the sub-emitter where it does.
//
// Godot inlines start() and process() into its own particle shader and rejects `return`
// inside either, so every early exit below is written as a condition instead.
//
// CUSTOM: x = random 0..1 for the draw shader, y = age 0..1, z = size in metres,
// w = lifetime in seconds.
shader_type particles;

#include "res://shaders/gerstner_waves.gdshaderinc"
#include "res://shaders/particle_common.gdshaderinc"

group_uniforms Emission;
// Fraction of restarts allowed to look for a crest. Derived from wind speed by OceanSpray.
uniform float spray_amount : hint_range(0.0, 1.0) = 1.0;
// Fraction of launched droplets that are spindrift rather than spray. Also wind-derived.
uniform float spindrift_amount : hint_range(0.0, 1.0) = 0.0;
// Radius around the emitter searched for breaking crests, in metres.
uniform float spawn_radius : hint_range(1.0, 400.0) = 90.0;
// Closest a candidate may be to the emitter, so spray does not burst through the camera.
uniform float spawn_inner_radius : hint_range(0.0, 50.0) = 3.0;
// Points of sea examined per restart. More finds crests more reliably, at linear cost.
uniform int candidate_count : hint_range(1, 16) = 8;
// Compression below which water is breaking. Kept equal to the ocean's whitecap threshold,
// so spray leaves exactly the crests that foam.
uniform float breaking_threshold : hint_range(0.0, 1.0) = 0.84;
// Compression below the threshold over which breaking reaches full strength.
uniform float breaking_range : hint_range(0.01, 1.0) = 0.25;
group_uniforms;

group_uniforms Flight;
// Speed at which spray leaves a crest along its normal, in m/s: minimum and maximum.
uniform vec2 launch_speed = vec2(1.5, 4.5);
// Wind speed ten metres above the surface, in m/s. Pushed from the WaveField.
uniform float wind_speed : hint_range(0.0, 40.0) = 10.0;
// Wind at spray height as a fraction of the ten-metre wind. The wind speed profile over
// the sea is logarithmic, which puts the wind a metre or two up at about 70% of it.
uniform float wind_fraction : hint_range(0.0, 1.0) = 0.7;
// Drag rate toward the wind for the smallest droplet, in 1/s. Drag per unit mass goes as
// 1/size, so larger droplets feel proportionally less and fly further before settling.
uniform float air_drag : hint_range(0.0, 20.0) = 3.0;
// Drawn size of a droplet, in metres: minimum and maximum.
uniform vec2 droplet_size = vec2(0.06, 0.34);
// Lifetime of a droplet that never lands, in seconds: minimum and maximum.
uniform vec2 lifetime_range = vec2(0.9, 2.2);
group_uniforms;

group_uniforms Ripples;
// Rings are only left within this distance of the viewer; beyond it they are sub-pixel.
uniform float ripple_max_distance : hint_range(0.0, 200.0) = 45.0;
// Ring radius as a multiple of the droplet's size.
uniform float ripple_scale : hint_range(0.5, 10.0) = 2.5;
uniform float ripple_lifetime : hint_range(0.1, 4.0) = 0.8;
uniform vec3 viewer_position = vec3(0.0);
group_uniforms;

// Returns the wind at spray height as a world velocity.
vec3 spray_height_wind() {
	float heading = radians(wind_angle);
	return vec3(cos(heading), 0.0, sin(heading)) * wind_speed * wind_fraction;
}

// Returns the rest position of the hardest-breaking of `candidate_count` random points of sea
// around `centre`, with how hard it is breaking (0..1) in `breaking`.
vec2 find_breaking_crest(vec2 centre, inout uint state, out float breaking) {
	vec2 best_origin = centre;
	breaking = 0.0;
	for (int i = 0; i < candidate_count; i++) {
		float angle = TAU * particle_random(state);
		// Linear in radius rather than square-root: density falls off as 1/r, which roughly
		// matches how much of the screen a patch of sea covers in perspective.
		float radius = mix(spawn_inner_radius, spawn_radius, particle_random(state));
		vec2 origin = centre + radius * vec2(cos(angle), sin(angle));
		vec3 candidate_normal;
		float compression;
		wave_sample(origin, wave_time, candidate_normal, compression);
		float candidate = clamp((breaking_threshold - compression) / breaking_range, 0.0, 1.0);
		if (candidate > breaking) {
			breaking = candidate;
			best_origin = origin;
		}
	}
	return best_origin;
}

void start() {
	uint state = particle_seed(RANDOM_SEED, NUMBER);
	CUSTOM = vec4(particle_random(state), 0.0, droplet_size.x, 1.0);
	ACTIVE = false;

	if (particle_random(state) < spray_amount) {
		float breaking;
		vec2 origin = find_breaking_crest(EMISSION_TRANSFORM[3].xz, state, breaking);

		// Launch with a probability equal to how hard the crest is breaking, so the edge of a
		// whitecap throws a little spray and its heart throws a lot.
		if (particle_random(state) < breaking) {
			vec3 normal;
			float compression;
			vec3 displacement = wave_sample(origin, wave_time, normal, compression);
			vec3 surface = vec3(origin.x, sea_level, origin.y) + displacement;

			bool spindrift = particle_random(state) < spindrift_amount;
			float size_pick = particle_random(state);
			// Spindrift is the finest spray, torn off by the wind; ordinary spray is mostly
			// small with a few large clumps, hence the squared distribution.
			float size = spindrift
				? mix(droplet_size.x, droplet_size.x * 2.0, size_pick)
				: mix(droplet_size.x, droplet_size.y, size_pick * size_pick);

			float launch = mix(launch_speed.x, launch_speed.y, particle_random(state));
			launch *= 0.5 + 0.5 * breaking;
			vec3 velocity = wave_velocity(origin, wave_time);
			if (spindrift) {
				// Torn sideways off the crest top rather than thrown up out of it.
				velocity += normal * launch * 0.3 + spray_height_wind() * 0.6;
			} else {
				velocity += normal * launch;
			}

			float lifetime = mix(lifetime_range.x, lifetime_range.y, particle_random(state));
			CUSTOM = vec4(CUSTOM.x, 0.0, size, lifetime);
			VELOCITY = velocity;
			TRANSFORM = particle_streak_transform(surface + normal * size * 0.5, velocity, size);
			ACTIVE = true;
		}
	}
}

void process() {
	float age = CUSTOM.y + DELTA / max(CUSTOM.w, 0.001);
	if (age >= 1.0) {
		ACTIVE = false;
	}

	if (ACTIVE) {
		CUSTOM.y = age;
		float size = CUSTOM.z;

		// Gravity, then drag toward the moving air. The drag is integrated exactly (the
		// exponential), so a small droplet in a gale cannot overshoot the wind at a large DELTA.
		float drag = air_drag * droplet_size.x / max(size, 0.001);
		VELOCITY.y -= WAVE_GRAVITY * DELTA;
		VELOCITY += (spray_height_wind() - VELOCITY) * (1.0 - exp(-drag * DELTA));

		vec3 position = TRANSFORM[3].xyz;
		bool landed = false;
		// Nothing above the tallest possible crest can be under water, which spares the
		// surface inversion for most of a droplet's flight.
		if (VELOCITY.y < 0.0 && position.y < sea_level + wave_total_amplitude) {
			float surface = wave_surface_height(position.xz, wave_time);
			landed = position.y <= surface;
			if (landed && distance(position, viewer_position) < ripple_max_distance) {
				mat4 landing = mat4(1.0);
				landing[3] = vec4(position.x, surface, position.z, 1.0);
				emit_subparticle(
					landing,
					vec3(0.0),
					vec4(1.0),
					vec4(CUSTOM.x, 0.0, size * ripple_scale, ripple_lifetime),
					FLAG_EMIT_POSITION | FLAG_EMIT_CUSTOM);
			}
		}

		if (landed) {
			ACTIVE = false;
		} else {
			TRANSFORM = particle_streak_transform(position, VELOCITY, size);
		}
	}
}

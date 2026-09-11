// Ripple rings left where a droplet or raindrop meets the sea.
//
// Only ever emitted by another system through emit_subparticle(); this one never emits on
// its own. A ring does not stay where it was dropped: it is pinned to the water that was
// there and follows that water round its orbit and up and down the swell. That is what
// makes it read as a disturbance in the surface rather than a decal lying on top of it.
//
// Godot rejects `return` inside start() and process(), so early exits are conditions.
//
// CUSTOM: x = random 0..1, y = age 0..1, z = radius in metres, w = lifetime in seconds.
// USERDATA1.xy = the rest position of the water the ring is pinned to.
shader_type particles;
render_mode disable_velocity;

#include "res://shaders/gerstner_waves.gdshaderinc"

// Height the ring floats above the surface, in metres.
//
// The ring is opaque and drawn before the ocean, which then depth-tests against it; at the
// same depth the two would z-fight. It also covers the gap between the analytic surface and
// the ocean mesh, which is flat between vertices and so sits slightly under a crest.
uniform float ripple_lift : hint_range(0.0, 0.5) = 0.05;

// Returns the ring's transform: sitting on the water that rests at `origin`, lying in the
// surface, scaled to `radius`.
mat4 ring_transform(vec2 origin, float radius) {
	vec3 normal;
	float compression;
	vec3 displacement = wave_sample(origin, wave_time, normal, compression);
	vec3 centre = vec3(origin.x, sea_level, origin.y) + displacement + normal * ripple_lift;
	vec3 helper = abs(normal.z) < 0.99 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(normal, helper));
	// Right-handed, so the plane mesh's up face is the one that faces the sky.
	vec3 bitangent = cross(tangent, normal);
	return mat4(
		vec4(tangent * radius, 0.0),
		vec4(normal, 0.0),
		vec4(bitangent * radius, 0.0),
		vec4(centre, 1.0));
}

void start() {
	// Restarted without a position means not emitted by anyone: this system has nothing to
	// draw on its own.
	ACTIVE = !RESTART_POSITION;
	if (ACTIVE) {
		vec2 origin = wave_origin_below(TRANSFORM[3].xz, wave_time);
		USERDATA1 = vec4(origin, 0.0, 0.0);
		CUSTOM.y = 0.0;
		TRANSFORM = ring_transform(origin, CUSTOM.z);
	}
}

void process() {
	float age = CUSTOM.y + DELTA / max(CUSTOM.w, 0.001);
	if (age >= 1.0) {
		ACTIVE = false;
	}
	if (ACTIVE) {
		CUSTOM.y = age;
		TRANSFORM = ring_transform(USERDATA1.xy, CUSTOM.z);
	}
}

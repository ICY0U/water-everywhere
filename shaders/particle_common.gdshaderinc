// Helpers shared by the particle process shaders.

// Returns a well-mixed hash of `x` (the "lowbias32" integer finaliser).
//
// RANDOM_SEED is only a starting point: every random choice a particle makes needs its own
// value, and chaining this hash gives each particle an independent sequence without any
// shared state. The constants are written in decimal because they exceed the signed range.
uint particle_hash(uint x) {
	x ^= x >> 16u;
	x *= 2146121005u;
	x ^= x >> 15u;
	x *= 2221713035u;
	x ^= x >> 16u;
	return x;
}

// Advances `state` and returns a uniform random number in [0, 1).
float particle_random(inout uint state) {
	state = particle_hash(state);
	return float(state >> 8u) / 16777216.0;
}

// Returns a seed unique to this particle and this restart of it.
//
// RANDOM_SEED alone repeats between particles restarted on the same frame; folding in the
// emission NUMBER keeps neighbouring particles from making the same choices.
uint particle_seed(uint random_seed, uint number) {
	return particle_hash(random_seed ^ particle_hash(number + 40503u));
}

// Packs a droplet into a particle transform for spray_droplet.gdshader.
//
// Column 0 carries the velocity itself; columns 1 and 2 are a perpendicular pair scaled to
// the droplet's size. The draw shader rebuilds a velocity-stretched billboard from those.
// The basis is kept orthogonal and right-handed, rather than packing the data into zero
// columns, so nothing downstream ever inverts a singular or mirrored matrix.
mat4 particle_streak_transform(vec3 position, vec3 velocity, float size) {
	float speed = length(velocity);
	vec3 axis = speed > 0.00001 ? velocity / speed : vec3(0.0, -1.0, 0.0);
	vec3 helper = abs(axis.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 side = normalize(cross(axis, helper));
	vec3 up = cross(axis, side);
	return mat4(
		vec4(axis * max(speed, 0.00001), 0.0),
		vec4(side * size, 0.0),
		vec4(up * size, 0.0),
		vec4(position, 1.0));
}

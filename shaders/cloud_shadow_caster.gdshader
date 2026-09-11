// An invisible slab that casts the sky's clouds as shadows, so the ocean gets god rays.
//
// WHY THIS EXISTS
//
// Volumetric god rays are the sun's shadow written into the froxel grid, so something must
// interrupt the light. Over open ocean nothing does: wave crests are a metre tall and cast
// nothing usable even at a grazing sun (measured - a 6 degree sun with 80x shaft energy
// produced a uniformly white frame with no shaft structure at all). Real sea god rays come
// from CLOUD occlusion, and the clouds here are drawn by the sky shader, which is a
// background pass and casts nothing.
//
// Godot's DirectionalLight3D light_projector does not solve this either: tested with a hard
// black/white striped cookie, it modulated neither surfaces nor volumetric fog. (It is a
// long-standing engine gap - world-space cloud shadows for directional lights are an open
// proposal, not a feature.)
//
// So the occluder is made explicitly. This shader goes on a large horizontal quad placed
// above the camera, rendered ONLY into the shadow map:
//
//   * discard in fragment() makes it invisible to the camera, while the shadow pass still
//     runs, so the slab is never seen but always casts.
//   * The same FBM the sky uses is thresholded into cloud shapes, and fragments outside a
//     cloud are discarded in the shadow pass too - so light passes between the clouds and
//     is blocked under them.
//
// The result is cloud-shaped holes in the sunlight, which the froxel grid turns into
// shafts, and which also dapple the water surface. One occluder drives both.
//
// KEEPING IT IN SYNC WITH THE SKY
//
// The cloud field must match cel_sky.gdshader or the shadows land where no cloud is drawn.
// The noise, coverage and drift parameters are duplicated here rather than shared, because
// the sky projects its clouds onto a plane in VIEW direction while this samples them in
// WORLD position. Both must describe the same clouds; neither can use the other's
// coordinates directly. WeatherPreset writes both from one place, which is what keeps them
// honest.
shader_type spatial;
// unshaded + depth_draw_never: the slab is never lit and never writes depth, so it cannot
// occlude the camera's view of the sky. It must still CAST, so shadows_disabled must not be
// set here - that would switch off the one thing this shader exists to do. Godot has no
// shadows_only mode, so invisibility comes from discarding in fragment() instead.
// depth_draw_opaque, NOT depth_draw_never: a shadow map IS a depth buffer, so a material
// that never writes depth writes nothing into it and casts no shadow. Invisibility comes
// from SHADOW_CASTING_SETTING_SHADOWS_ONLY on the instance instead, which keeps the mesh
// out of the colour pass entirely while still rendering it into the shadow map.
render_mode unshaded, depth_draw_opaque, cull_disabled;

group_uniforms Clouds;
// Fraction of sky covered. Must match the sky's cloud_coverage or shadows fall on clear sky.
uniform float coverage : hint_range(0.0, 1.0) = 0.42;
// Edge hardness of a cloud's shadow. Near zero gives a hard-edged painted shadow, which is
// what cel wants; a little width softens the shaft edges.
uniform float edge : hint_range(0.001, 0.4) = 0.06;
// World-space size of the cloud cells, in metres per unit of noise.
uniform float scale : hint_range(1.0, 2000.0) = 260.0;
uniform int octaves : hint_range(1, 6) = 4;
group_uniforms;

group_uniforms Drift;
uniform vec2 wind_direction = vec2(1.0, 0.35);
uniform float wind_speed : hint_range(0.0, 40.0) = 6.0;
// Driven from Atmosphere, not TIME: the project runs one clock so the shadows cannot drift
// at a different rate from the sky they are supposed to belong to.
uniform float cloud_time = 0.0;
group_uniforms;

group_uniforms Strength;
// How much of the sky is allowed to cast at all. 0 disables the caster entirely, which is
// the right setting for overcast (a solid lid casts no beams, it just dims everything).
uniform float shadow_amount : hint_range(0.0, 1.0) = 1.0;
group_uniforms;

// Value noise matched to the sky's, so both describe the same cloud field.
float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
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

float fbm(vec2 p, int octave_count) {
	float total = 0.0;
	float amplitude = 0.5;
	float weight = 0.0;
	for (int i = 0; i < 6; i++) {
		if (i >= octave_count) {
			break;
		}
		total += value_noise(p) * amplitude;
		weight += amplitude;
		p *= 2.02;
		amplitude *= 0.5;
	}
	return total / max(weight, 0.0001);
}

// World XZ of this fragment. shadow() has no MODEL_MATRIX (verified: the compiler rejects
// it there), so the world position has to be carried across from vertex().
varying vec2 slab_world_xz;

void vertex() {
	slab_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	// Belt and braces. The instance is set to SHADOWS_ONLY, so this never runs in practice;
	// it keeps the slab invisible if someone flips that setting while debugging.
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}

// Runs only in the shadow pass. Discarding here is what punches cloud-shaped holes in the
// sunlight: kept fragments block the sun, discarded ones let it through.
void shadow() {
	if (shadow_amount <= 0.0) {
		discard;
	}

	vec2 world_xz = slab_world_xz;
	vec2 drift = normalize(wind_direction + vec2(0.0001)) * wind_speed * cloud_time;
	float density = fbm((world_xz + drift) / scale, octaves);

	// Same hard threshold the sky uses, so the shadow edge matches the drawn cloud edge.
	// cloud == 1 inside a cloud, 0 in clear sky.
	float cloud = smoothstep(1.0 - coverage - edge, 1.0 - coverage + edge, density);

	// Keep the fragment only where there IS a cloud; clear sky must let the sun through.
	//
	// The sense of this test matters more than it looks. Getting it backwards makes the
	// slab an almost-solid lid rather than scattered clouds, and the entire ocean goes into
	// shadow - which looks like "shadows are broken" rather than like a threshold bug.
	//
	// shadow_amount scales how much of the field counts as cloud: 1.0 casts every cloud,
	// 0.0 casts none. It raises the bar a fragment must clear, rather than making the
	// shadow translucent, because a partial shadow would be a soft gradient.
	if (cloud * shadow_amount < 0.5) {
		discard;
	}
}

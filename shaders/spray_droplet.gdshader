// Draws one spray droplet or raindrop: a velocity-stretched billboard with a hard, lumpy
// edge, dissolving into holes as it ages.
//
// Hard edges are not only the style. The ocean is drawn in the transparent pass and writes
// no depth, so an alpha-BLENDED particle behind a swell would be painted over that swell
// instead of being hidden by it. Alpha scissor keeps this material opaque — it writes depth
// and so is correctly hidden by the water in front of it — which is also exactly the
// cut-out silhouette cel spray wants.
//
// Reads the particle transform packed by particle_streak_transform(): column 0 is the
// velocity, and the length of column 1 is the droplet's size.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, world_vertex_coords, specular_disabled;

#include "res://shaders/particle_cel_light.gdshaderinc"

group_uniforms Look;
uniform vec3 albedo : source_color = vec3(0.96, 0.98, 1.0);
// Seconds of travel a streak spans — stylised motion blur. 0 draws round blobs.
uniform float streak_time : hint_range(0.0, 0.5) = 0.04;
// Narrowest a droplet may become on screen, in pixels. Sub-pixel geometry blinks in and
// out as it crosses pixel centres, which reads as noise rather than as spray or rain.
uniform float min_pixel_width : hint_range(0.0, 8.0) = 1.5;
// How far the silhouette is broken into lumps. 0 is a clean capsule.
uniform float edge_noise : hint_range(0.0, 1.5) = 0.6;
// Age (0..1) at which the droplet starts to dissolve.
uniform float erosion_start : hint_range(0.0, 1.0) = 0.45;
// Width of a streak's trailing end, as a fraction of its head.
uniform float tail_taper : hint_range(0.0, 1.0) = 0.65;
// Distance within which a droplet fades out entirely, in metres. 0 disables it.
//
// A drop passing a hand's breadth from the camera is drawn a metre long across the whole
// frame, which reads as a scratch on the lens rather than as rain. Real cameras have the
// same drops out of focus and invisible; here they are simply removed.
uniform float near_fade : hint_range(0.0, 10.0) = 0.0;
group_uniforms;

varying flat float v_seed;
varying flat float v_age;
// Length and width of the drawn shape, in world units, as half-extents.
varying flat float v_half_length;
varying flat float v_half_width;
// World-space frame of the billboard: along the streak, across it, and toward the camera.
varying flat vec3 v_axis;
varying flat vec3 v_side;
varying flat vec3 v_facing;
varying flat float v_near_fade;

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

void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	vec3 velocity = MODEL_MATRIX[0].xyz;
	float size = length(MODEL_MATRIX[1].xyz);
	// The main camera even in the shadow pass, so a droplet's shadow has its drawn shape.
	vec3 camera = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
	vec3 facing = normalize(camera - centre);

	float camera_distance = distance(camera, centre);
	v_near_fade = near_fade > 0.0
		? smoothstep(near_fade * 0.55, near_fade, camera_distance)
		: 1.0;

	// World size of one pixel at this distance.
	float pixel = 2.0 * camera_distance / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float half_width = max(size * 0.5, pixel * min_pixel_width * 0.5);

	// Only the part of the velocity across the view shows as streak length: a drop coming
	// straight at the camera is a dot, not a line.
	vec3 across = velocity - dot(velocity, facing) * facing;
	float screen_speed = length(across);
	vec3 fallback = abs(facing.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 axis = screen_speed > 0.0001 ? across / screen_speed : normalize(cross(facing, fallback));
	vec3 side = cross(facing, axis);
	float half_length = half_width + 0.5 * screen_speed * streak_time;

	// The head sits on the particle and the streak trails behind it.
	vec2 corner = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	vec3 trail_centre = centre - axis * (half_length - half_width);
	VERTEX = trail_centre + axis * corner.x * half_length + side * corner.y * half_width;
	NORMAL = facing;

	v_seed = INSTANCE_CUSTOM.x;
	v_age = INSTANCE_CUSTOM.y;
	v_half_length = half_length;
	v_half_width = half_width;
	v_axis = axis;
	v_side = side;
	v_facing = facing;
}

void fragment() {
	vec2 corner = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	float aspect = v_half_length / v_half_width;

	// Position in units of the half-width. The shape is a capsule whose straight section
	// runs the length of the streak, narrowing toward the tail.
	float along = corner.x * aspect;
	float segment = aspect - 1.0;
	float taper = mix(tail_taper, 1.0, clamp(corner.x * 0.5 + 0.5, 0.0, 1.0));
	vec2 local = vec2(along - clamp(along, -segment, segment), corner.y / taper);
	float radial = length(local);

	// Lumpy silhouette. Seeded per droplet so no two share a shape.
	float lumps = value_noise(local * 1.7 + vec2(v_seed * 37.0, v_seed * 53.0));
	float body = 1.0 - radial + (lumps - 0.5) * edge_noise;

	// Holes eating in from the inside as the droplet atomises. Summed value noise clusters
	// around 0.5 and would never cross the cut, so it is contrast-stretched first.
	float holes = value_noise(vec2(along, corner.y) * 2.3 + vec2(v_seed * 91.0, 11.0));
	holes = clamp((holes - 0.5) * 2.2 + 0.5, 0.0, 1.0);
	// The threshold starts BELOW the noise floor rather than at zero, so a droplet that is
	// not eroding yet is whole. Starting at zero cut holes wherever the stretched noise had
	// clamped to 0, which broke every un-eroding rain streak into a beaded chain.
	//
	// The upper edge is held clear of erosion_start because smoothstep divides by the gap
	// between its edges: at erosion_start = 1.0, which is how rain switches erosion off
	// entirely, smoothstep(1.0, 1.0, age) divides by zero and the whole droplet goes NaN.
	float erosion = mix(-0.3, 1.05, smoothstep(erosion_start, max(erosion_start + 0.001, 1.0), v_age));

	ALPHA = clamp(min(body, holes - erosion) * 8.0 + 0.5, 0.0, 1.0) * v_near_fade;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALBEDO = albedo;

	// Light it as a small sphere (or a capsule, when stretched), so each droplet gets a lit
	// side and a shaded side from the same bands the water uses.
	float bulge = sqrt(max(1.0 - radial * radial, 0.0));
	vec3 world_normal = normalize(v_axis * local.x + v_side * local.y + v_facing * bulge);
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
}

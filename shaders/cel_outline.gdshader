// Inverse-hull outline. Assign as a next_pass on a cel material.
//
// Draws the mesh a second time, expanded along its normals with front faces culled, so the
// expanded copy is visible only where it protrudes past the original — as a border around
// the silhouette. The technique dates to Jet Set Radio (1999) and is what Arc System Works
// ship in the Guilty Gear Xrd series.
//
// Two controls make the line read as ink rather than as a traced offset:
//   * width scales with view depth, so it holds a constant thickness on screen;
//   * vertex colour alpha scales it per-vertex, so artists can vary line weight along a
//     form and switch the line off entirely where it is not wanted.
shader_type spatial;
render_mode blend_mix, cull_front, depth_draw_opaque, unshaded;

uniform vec3 outline_color : source_color = vec3(0.06, 0.08, 0.13);
uniform float outline_width : hint_range(0.0, 20.0) = 2.0;

// Hold a constant on-screen width by scaling the expansion with view depth. Disable for a
// fixed world-space thickness, where lines thin out with distance.
uniform bool constant_screen_width = true;

// Distance past which the width stops growing, in metres. Without a cap, geometry far from
// the camera expands enough to swamp the frame.
uniform float max_distance : hint_range(1.0, 2000.0) = 400.0;

// Expand along the tangent instead of the normal.
//
// At a hard edge — split normals, separate smoothing groups, a UV seam — one position
// carries several different normals. Expanding along each pushes coincident vertices apart
// and the hull tears open, breaking the outline into disconnected fragments at every hard
// edge. The fix is to expand along a *smooth* normal (every normal at that position
// averaged) while still lighting with the real ones.
//
// Tangents are the conventional place to bake those smooth normals: toon materials rarely
// use normal maps, so the channel is free, and unlike vertex colours a tangent follows
// skeletal deformation. Enable this only when the mesh actually carries baked smooth
// normals in its tangents; on a smooth-shaded mesh the plain normal is already correct.
uniform bool use_tangent_as_smooth_normal = false;

// Scale the width by vertex colour alpha, with 0.5 as the neutral baseline, so artists can
// author both thinner and thicker than default and remove the line entirely at 0.0.
uniform bool use_vertex_color_width = false;


void vertex() {
	float width = outline_width * 0.01;

	if (constant_screen_width) {
		float view_depth = -(VIEW_MATRIX * MODEL_MATRIX * vec4(VERTEX, 1.0)).z;
		width *= clamp(view_depth, 0.0, max_distance);
	}

	if (use_vertex_color_width) {
		width *= COLOR.a * 2.0;
	}

	vec3 expansion_normal = use_tangent_as_smooth_normal ? TANGENT : NORMAL;
	VERTEX += normalize(expansion_normal) * width;
}


void fragment() {
	ALBEDO = outline_color;
}

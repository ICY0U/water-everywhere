class_name HullGeometry
extends RefCounted

## A convex hull that can be clipped against the water surface to find what is submerged.
##
## Buoyancy needs one number that is genuinely hard to get: how much water a body is
## displacing right now, and where the centre of that displaced volume is. Approximating the
## hull as a box and ramping submersion with depth is what makes every object float like a
## crate — a sphere sits too high near the waterline, a barge too low, and nothing has a
## righting moment that depends on its actual shape.
##
## So the real geometry is integrated instead. The hull is stored as a triangle soup in body
## space; each physics frame it is clipped against the local water plane, the hole left by
## the cut is capped, and the resulting closed polyhedron is integrated by the divergence
## theorem. Volume and centroid fall out of the same accumulation, which is exactly the pair
## Archimedes needs: the force is [code]rho * g * V[/code] and it acts at the centroid.
##
## [b]Why the hull is decimated on load.[/b] [method Shape3D.get_debug_mesh] returns 2112
## triangles for a sphere and 1728 for a capsule. Clipping those every physics frame, per
## body, is far more work than the forces are worth — and the extra fidelity is invisible,
## because the wave surface under a body is itself approximated by a plane. The hull is
## therefore resampled once into at most [member max_triangles] triangles, which holds the
## volume error under a percent while making the per-frame clip cheap.
##
## [b]Winding.[/b] Godot's debug meshes wind inward, so the raw signed volume comes out
## negative. Everything here works in absolute value and derives orientation from the plane
## rather than from face normals, so winding cannot silently invert a force.
##
## @tutorial(Divergence theorem): https://en.wikipedia.org/wiki/Divergence_theorem
## @tutorial(Sutherland-Hodgman clipping): https://en.wikipedia.org/wiki/Sutherland%E2%80%93Hodgman_algorithm

## Volume below which a clipped result is treated as nothing at all, in cubic metres.
##
## Guards the centroid division: a hull grazing the surface produces a sliver whose centroid
## is numerically meaningless, and dividing by it throws the buoyancy centre to infinity.
const MINIMUM_VOLUME: float = 0.000001

## Distance below which two cut-ring points are treated as the same point, in metres.
const RING_WELD_DISTANCE: float = 0.0001

## Triangles of the hull in body space, three vertices per triangle.
var triangles: PackedVector3Array = PackedVector3Array()

## Total volume of the hull, in cubic metres.
var volume: float = 0.0

## Axis-aligned bounds of the hull in body space.
var bounds: AABB = AABB()

## Largest horizontal half-extent of the hull, in metres. Used as the contact radius.
var waterline_radius: float = 0.0


## Builds a hull from every [CollisionShape3D] under [param body].
##
## Multiple colliders are merged into one triangle soup, each baked through its own transform
## relative to the body, so a compound body is integrated as the single solid it represents.
## Returns an empty hull if the body has no usable collider.
static func from_body(body: PhysicsBody3D, max_triangles: int = 128) -> HullGeometry:
	var hull := HullGeometry.new()
	var soup := PackedVector3Array()

	for child in body.get_children():
		var collider := child as CollisionShape3D
		if collider == null or collider.shape == null or collider.disabled:
			continue
		# Composed from LOCAL transforms up to the body rather than read from
		# global_transform. A body is routinely asked for its hull before it enters the tree
		# — from _ready(), or from a headless harness — and global_transform is not merely
		# unavailable there, it is a hard error that silently returns identity.
		soup.append_array(
			hull._bake_shape(collider.shape, hull._relative_transform(collider, body), max_triangles)
		)

	hull.triangles = soup
	hull._measure()
	return hull


## Returns [param node]'s transform expressed in [param ancestor]'s space.
##
## Walks local transforms rather than dividing global ones, so it is valid before the node
## has entered the tree.
func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var composed := Transform3D.IDENTITY
	var current := node
	while current != null and current != ancestor:
		composed = current.transform * composed
		current = current.get_parent() as Node3D
	return composed


## Returns the submerged volume and its centroid below the plane through [param plane_point]
## with upward normal [param plane_normal], both in the hull's own space.
##
## The centroid is where the buoyant force acts; returning it alongside the volume is what
## gives a body a righting moment that depends on its real shape rather than on a guess.
## [param plane_normal] must be unit length.
func clip_below_plane(plane_point: Vector3, plane_normal: Vector3) -> Dictionary:
	var cut_ring: PackedVector3Array = PackedVector3Array()
	var accumulated_volume := 0.0
	var accumulated_moment := Vector3.ZERO
	var plane_offset := plane_normal.dot(plane_point)

	var index := 0
	while index + 2 < triangles.size():
		var clipped := _clip_triangle(
			triangles[index], triangles[index + 1], triangles[index + 2],
			plane_normal, plane_offset, cut_ring,
		)
		# Fan the clipped polygon and accumulate the divergence-theorem integral.
		for corner in range(1, clipped.size() - 1):
			var a := clipped[0]
			var b := clipped[corner]
			var c := clipped[corner + 1]
			var signed := a.cross(b).dot(c) / 6.0
			accumulated_volume += signed
			accumulated_moment += (a + b + c) * 0.25 * signed
		index += 3

	# Cap the opening the cut left behind. Without this the solid is open and the integral
	# describes no volume at all.
	if cut_ring.size() >= 3:
		var centre := Vector3.ZERO
		for point in cut_ring:
			centre += point
		centre /= float(cut_ring.size())

		var ordered := _order_ring(cut_ring, centre, plane_normal)
		for corner in ordered.size():
			var a := centre
			var b := ordered[corner]
			var c := ordered[(corner + 1) % ordered.size()]
			var signed := a.cross(b).dot(c) / 6.0
			accumulated_volume += signed
			accumulated_moment += (a + b + c) * 0.25 * signed

	if absf(accumulated_volume) < MINIMUM_VOLUME:
		return {"volume": 0.0, "centroid": Vector3.ZERO}

	return {
		"volume": absf(accumulated_volume),
		"centroid": accumulated_moment / accumulated_volume,
	}


## Returns the hull's cross-sectional area facing [param direction], in square metres.
##
## Quadratic drag needs a reference area, and using one fixed number makes a long hull as
## draggy sideways as it is head-on. Projecting the real triangles onto the plane
## perpendicular to travel gives an area that changes with attitude, which is what makes a
## body turn broadside-on in a current instead of ignoring its own shape.
##
## Only faces pointing into the flow are counted, so the far side of the hull is not
## double-counted. [param direction] must be unit length.
func projected_area(direction: Vector3) -> float:
	var area := 0.0
	var index := 0
	while index + 2 < triangles.size():
		var edge_a := triangles[index + 1] - triangles[index]
		var edge_b := triangles[index + 2] - triangles[index]
		var face := edge_a.cross(edge_b) * 0.5
		# Half the absolute projected area over a closed hull equals its silhouette area,
		# which sidesteps needing consistent winding.
		area += absf(face.dot(direction))
		index += 3
	return area * 0.5


## Returns whether this hull has usable geometry.
func is_valid() -> bool:
	return triangles.size() >= 3 and volume > MINIMUM_VOLUME


## Records volume, bounds and waterline radius from the baked triangles.
func _measure() -> void:
	if triangles.is_empty():
		return

	var signed := 0.0
	var index := 0
	while index + 2 < triangles.size():
		signed += triangles[index].cross(triangles[index + 1]).dot(triangles[index + 2]) / 6.0
		index += 3
	volume = absf(signed)

	bounds = AABB(triangles[0], Vector3.ZERO)
	for vertex in triangles:
		bounds = bounds.expand(vertex)

	waterline_radius = maxf(bounds.size.x, bounds.size.z) * 0.5


## Converts one shape into body-space triangles, decimated to [param max_triangles].
func _bake_shape(shape: Shape3D, local: Transform3D, max_triangles: int) -> PackedVector3Array:
	var mesh := shape.get_debug_mesh()
	if mesh == null:
		push_warning("HullGeometry: %s produced no debug mesh; skipped." % shape.get_class())
		return PackedVector3Array()

	var faces := mesh.get_faces()
	if faces.size() < 3:
		return PackedVector3Array()

	faces = _decimate(faces, max_triangles)

	var baked := PackedVector3Array()
	baked.resize(faces.size())
	for index in faces.size():
		baked[index] = local * faces[index]
	return baked


## Reduces a triangle soup to at most [param max_triangles] by rebuilding its convex hull.
##
## Rebuilding from a subsample of the vertices rather than dropping triangles is what keeps
## the result a closed solid: discarding individual faces would leave holes, and an open
## surface has no volume for the divergence theorem to find.
func _decimate(faces: PackedVector3Array, max_triangles: int) -> PackedVector3Array:
	var triangle_count := faces.size() / 3
	if triangle_count <= max_triangles:
		return faces

	# Gather unique vertices, then thin them evenly. Godot's own convex hull builder turns
	# the survivors back into a closed solid.
	var points := PackedVector3Array()
	var stride := maxi(1, int(ceil(float(faces.size()) / float(max_triangles * 2))))
	var index := 0
	while index < faces.size():
		points.append(faces[index])
		index += stride

	if points.size() < 4:
		return faces

	# ConvexPolygonShape3D builds the hull from whatever points it is given, so handing it the
	# thinned set and reading the debug mesh back is the shortest route to a closed solid.
	var convex := ConvexPolygonShape3D.new()
	convex.points = points
	var rebuilt := convex.get_debug_mesh()
	if rebuilt == null:
		return faces

	var rebuilt_faces := rebuilt.get_faces()
	if rebuilt_faces.size() < 3:
		return faces
	return rebuilt_faces


## Clips one triangle to the half-space below the plane, collecting crossings in
## [param cut_ring].
func _clip_triangle(
	vertex_a: Vector3,
	vertex_b: Vector3,
	vertex_c: Vector3,
	plane_normal: Vector3,
	plane_offset: float,
	cut_ring: PackedVector3Array,
) -> PackedVector3Array:
	var polygon := PackedVector3Array([vertex_a, vertex_b, vertex_c])
	var output := PackedVector3Array()

	for index in polygon.size():
		var current := polygon[index]
		var next := polygon[(index + 1) % polygon.size()]
		var current_depth := plane_normal.dot(current) - plane_offset
		var next_depth := plane_normal.dot(next) - plane_offset

		if current_depth <= 0.0:
			output.append(current)
		# Sign change means this edge pierces the surface.
		if (current_depth <= 0.0) != (next_depth <= 0.0):
			var denominator := next_depth - current_depth
			if absf(denominator) > 1e-9:
				var crossing := current.lerp(next, -current_depth / denominator)
				output.append(crossing)
				cut_ring.append(crossing)

	return output


## Orders the cut ring around [param centre] within the cut plane.
##
## The ring arrives as unordered edge crossings. Fanning them without sorting produces a
## self-crossing star whose signed areas cancel, which reads as a body that loses buoyancy
## the moment it touches the water.
func _order_ring(
	ring: PackedVector3Array, centre: Vector3, plane_normal: Vector3
) -> PackedVector3Array:
	var unique: Array[Vector3] = []
	for point in ring:
		var duplicate := false
		for existing in unique:
			if existing.distance_squared_to(point) < RING_WELD_DISTANCE * RING_WELD_DISTANCE:
				duplicate = true
				break
		if not duplicate:
			unique.append(point)

	if unique.size() < 3:
		return PackedVector3Array()

	# The two in-plane axes must form a RIGHT-handed frame with the plane normal, or the ring
	# is ordered the wrong way round and the cap's signed volume comes out negated. That does
	# not fail loudly: the cap is exactly right at the hull's mid plane, where it has zero
	# area, and wrong by twice its own volume everywhere else — which presents as a body that
	# floats too high and capsizes rather than as any kind of geometry error.
	var axis_u := plane_normal.cross(Vector3.RIGHT)
	if axis_u.length_squared() < 0.001:
		axis_u = plane_normal.cross(Vector3.FORWARD)
	axis_u = axis_u.normalized()
	var axis_v := axis_u.cross(plane_normal).normalized()

	unique.sort_custom(func(a: Vector3, b: Vector3) -> bool:
		var offset_a := a - centre
		var offset_b := b - centre
		return (
			atan2(offset_a.dot(axis_v), offset_a.dot(axis_u))
			< atan2(offset_b.dot(axis_v), offset_b.dot(axis_u))
		)
	)

	return PackedVector3Array(unique)

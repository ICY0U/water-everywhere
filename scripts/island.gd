class_name Island
extends StaticBody3D

## A flat-topped island with a sloping beach, built as a radial height field at runtime.
##
## The shape is deliberately simple and analytic rather than sculpted or noise-driven: the
## profile is a function of distance from the centre, so [method height_at] can answer "how
## high is the ground here?" without touching the mesh. That is what lets tests assert against
## the island's geometry instead of against its collision shape's internals.
##
## The flat top exists for testing things that need level ground. The beach exists so the
## island meets the water at a slope a body can be washed up onto, and so the ocean's
## shoreline foam has shallow water to break over — depth-derived surf needs a gradual
## bottom, because a vertical wall produces a foam line exactly one pixel wide.
##
## The mesh and collision shape are generated in [method _ready] and their nodes are NOT given
## an owner, so nothing is serialised back into the scene file.

## Emitted once the mesh and collision shape have been rebuilt.
signal surface_rebuilt

## Height of the flat top, in metres above sea level.
##
## Must clear the worst-case wave crest or the "dry ground" this island exists to provide is
## washed over. See [method WaveField.total_amplitude].
@export_range(0.0, 40.0, 0.1) var deck_height: float = 4.0:
	set(value):
		deck_height = value
		_rebuild_if_ready()

## Distance from the centre out to which the top stays perfectly flat, in metres.
@export_range(1.0, 200.0, 0.5) var plateau_radius: float = 20.0:
	set(value):
		plateau_radius = value
		_rebuild_if_ready()

## Distance at which the beach slope ends and the steeper drop-off begins, in metres.
@export_range(2.0, 300.0, 0.5) var beach_radius: float = 40.0:
	set(value):
		beach_radius = value
		_rebuild_if_ready()

## Distance at which the drop-off reaches the sea bed, in metres.
@export_range(3.0, 400.0, 0.5) var shelf_radius: float = 50.0:
	set(value):
		shelf_radius = value
		_rebuild_if_ready()

## Height at the foot of the beach, in metres. Negative is below sea level.
##
## The beach runs from [member deck_height] down to this, so this value — not the sea bed —
## sets how far out the shallows reach, and therefore how wide the band of surf is.
@export_range(-20.0, 0.0, 0.1) var shelf_height: float = -1.5:
	set(value):
		shelf_height = value
		_rebuild_if_ready()

## Height of the sea bed beyond the drop-off, in metres.
##
## Deep enough that the island's own base is never in frame from a surface camera.
@export_range(-100.0, -1.0, 0.5) var base_depth: float = -12.0:
	set(value):
		base_depth = value
		_rebuild_if_ready()

## Half-width of the generated mesh, in metres.
@export_range(10.0, 400.0, 1.0) var extent: float = 60.0:
	set(value):
		extent = value
		_rebuild_if_ready()

## Number of quads along each axis of the height field.
@export_range(8, 400, 1) var resolution: int = 120:
	set(value):
		resolution = value
		_rebuild_if_ready()

## How much the shoreline's radius varies with bearing, as a fraction of the radius.
##
## A perfect circle reads as a poker chip. This is a fixed sum of sines rather than noise, so
## the island is identical on every run and a test can predict where the shore is.
@export_range(0.0, 0.4, 0.01) var shore_variation: float = 0.08:
	set(value):
		shore_variation = value
		_rebuild_if_ready()

## Material applied to the generated surface.
@export var material: Material:
	set(value):
		material = value
		if _mesh_instance != null:
			_mesh_instance.material_override = material

@export_group("Surf")

## Ocean to switch shoreline surf on for, or null to leave the water alone.
##
## The island is what knows a shore exists; the ocean is what draws surf. This is the wire
## between them.
@export var ocean: Ocean

## Strength of the surf the ocean draws where its water runs shallow. 0 leaves it off.
@export_range(0.0, 1.0, 0.01) var surf_strength: float = 0.9

## Water depth over which that surf fades out, in metres.
@export_range(0.05, 12.0, 0.05) var surf_depth: float = 2.5

## Extra depth the surf reaches as a crest passes, in metres.
@export_range(0.0, 8.0, 0.1) var surf_swash: float = 1.6

var _mesh_instance: MeshInstance3D
var _collision: CollisionShape3D


func _ready() -> void:
	rebuild()
	_apply_surf()


## Returns the ground height at a world-space column, in metres.
##
## The island's own transform is taken into account, so this answers in world space: a test can
## compare it directly against a body's global position.
func height_at_world(world_xz: Vector2) -> float:
	var local := to_local(Vector3(world_xz.x, 0.0, world_xz.y))
	return global_position.y + _profile(Vector2(local.x, local.z))


## Returns the horizontal distance from the centre out to the waterline, for a bearing.
##
## [param bearing] is in radians. The waterline is where the beach profile crosses the height
## the sea sits at relative to this island's origin, found by bisection because the profile is
## smoothstepped and has no closed-form inverse.
func waterline_radius(bearing: float = 0.0, sea_level: float = 0.0) -> float:
	var target := sea_level - global_position.y
	var direction := Vector2(cos(bearing), sin(bearing))
	var low := 0.0
	var high := shelf_radius * (1.0 + shore_variation)
	# The profile descends monotonically, so the crossing is unique and bisection is exact
	# enough in a handful of steps.
	for _step: int in 40:
		var middle := (low + high) * 0.5
		if _profile(direction * middle) > target:
			low = middle
		else:
			high = middle
	return (low + high) * 0.5


## Rebuilds the surface mesh and its collision shape.
func rebuild() -> void:
	_ensure_children()

	var mesh := _build_mesh()
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = material
	# Trimesh collision matches the rendered surface exactly. A height-map shape would be
	# cheaper, but it cannot be scaled without scaling the collision node itself, which Godot
	# handles poorly for static geometry.
	_collision.shape = mesh.create_trimesh_shape()

	surface_rebuilt.emit()


## Switches the ocean's shoreline surf on, working on a private copy of its material.
##
## The material is shared with the other scenes through [code]ocean_material.tres[/code], so it
## is duplicated before anything is written to it. Enabling surf on the shared resource would
## put a white rim at the waterline of every floating object in every scene that loads it —
## the depth buffer cannot tell a submerged hull from a sea bed.
func _apply_surf() -> void:
	var source := ocean.material if ocean != null else null
	if source == null or surf_strength <= 0.0:
		return

	var surf_material := source.duplicate() as ShaderMaterial
	surf_material.set_shader_parameter(&"shore_foam_strength", surf_strength)
	surf_material.set_shader_parameter(&"shore_foam_depth", surf_depth)
	surf_material.set_shader_parameter(&"shore_foam_swash", surf_swash)
	ocean.material = surf_material


## Returns the ground height at a point in the island's own space, in metres.
func _profile(local_xz: Vector2) -> float:
	var distance := local_xz.length()
	if is_zero_approx(distance):
		return deck_height

	var scale := _bearing_scale(atan2(local_xz.y, local_xz.x))
	var plateau := plateau_radius * scale
	var beach := beach_radius * scale
	var shelf := shelf_radius * scale

	if distance <= plateau:
		return deck_height
	if distance < beach:
		var t := (distance - plateau) / maxf(beach - plateau, 0.0001)
		return lerpf(deck_height, shelf_height, smoothstep(0.0, 1.0, t))
	if distance < shelf:
		var t := (distance - beach) / maxf(shelf - beach, 0.0001)
		return lerpf(shelf_height, base_depth, smoothstep(0.0, 1.0, t))
	return base_depth


## Returns the radius multiplier for a bearing, in radians.
func _bearing_scale(bearing: float) -> float:
	return 1.0 + (sin(bearing * 3.0) * 0.6 + sin(bearing * 5.0 + 1.7) * 0.4) * shore_variation


func _build_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var quad_size := extent * 2.0 / resolution

	for z in resolution + 1:
		for x in resolution + 1:
			var position := Vector2(x * quad_size - extent, z * quad_size - extent)
			vertices.append(Vector3(position.x, _profile(position), position.y))
			uvs.append(Vector2(float(x) / resolution, float(z) / resolution))

	# Wound clockwise seen from above, matching Ocean._append_quad_indices. Godot treats
	# clockwise as front-facing; reversing it leaves the island back-facing, and cull_back
	# then discards it entirely — which presents as the island being absent, not as an error.
	var stride := resolution + 1
	for z in resolution:
		for x in resolution:
			var corner := z * stride + x
			indices.append_array([corner, corner + 1, corner + stride])
			indices.append_array([corner + 1, corner + stride + 1, corner + stride])

	var surface_arrays := []
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = vertices
	surface_arrays[Mesh.ARRAY_TEX_UV] = uvs
	surface_arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)

	# The surface is lit rather than analytic, so it needs real normals. Generating them from
	# the committed geometry keeps them consistent with the winding above.
	var tool := SurfaceTool.new()
	tool.create_from(mesh, 0)
	tool.generate_normals()
	return tool.commit()


## Creates the mesh and collision children, without giving them an owner.
##
## An owned child is serialised into the [code].tscn[/code] when the scene is saved, which
## would bake this generated geometry into the scene file permanently.
func _ensure_children() -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Mesh"
		add_child(_mesh_instance)
	if _collision == null:
		_collision = CollisionShape3D.new()
		_collision.name = "Collision"
		add_child(_collision)


func _rebuild_if_ready() -> void:
	if is_inside_tree():
		rebuild()

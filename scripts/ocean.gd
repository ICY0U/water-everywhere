class_name Ocean
extends Node3D

## An endless, cel-shaded ocean surface driven by a Gerstner wave spectrum.
##
## The surface is built from concentric mesh rings centred on the viewer. The innermost
## ring is a dense grid; each successive ring doubles its quad size and is hollow, so
## triangle density falls off with distance while screen-space density stays roughly
## constant. Rings are re-centred every frame and snapped to their own quad size, which is
## what prevents the surface from shimmering as the camera moves.
##
## Wave motion is defined by [member wave_field]. That same resource is evaluated on the
## CPU by [method get_water_height] and its siblings, so gameplay code can ask where the
## water actually is without reading back from the GPU.
##
## This node is the front door to the water, and it carries two separate channels for things
## interacting with it. Continuous presence — a hull sitting in the sea, denting it and
## churning foam — is reported through [method report_contact] and read back through
## [method get_active_contacts]. Discrete moments — something entering, leaving or slamming
## into the surface — are raised through [method report_impact] and delivered by
## [signal water_impacted].
##
## The split is deliberate. An effect that fires once per splash would otherwise have to
## filter a per-frame signal for the frames it cared about, and an effect that needs ongoing
## state would have to accumulate its own history from events. Contacts also expire on a
## timer rather than being cleared each frame, because they arrive on the physics clock and
## are consumed on the render clock; clearing would strobe every wake.
##
## It also owns the wave clock. Everything that evaluates the spectrum — the surface
## shader, the foam simulation, CPU queries — is driven from [member elapsed_time] here, so
## none of them can drift apart.
##
## @tutorial(Trochoidal (Gerstner) waves): https://en.wikipedia.org/wiki/Trochoidal_wave

## Emitted after the ring meshes have been rebuilt by [method rebuild].
signal surface_rebuilt

## Emitted when something enters, leaves or slams into the surface.
##
## Discrete events only; see [WaterImpact]. For the ongoing state of things already in the
## water, poll [method get_active_contacts] instead.
signal water_impacted(impact: WaterImpact)

## What kind of moment a [WaterImpact] describes.
enum ImpactKind {
	## Something crossed into the water.
	ENTRY,
	## Something left the water.
	EXIT,
	## Something already in the water struck it hard after being nearly still.
	SLAM,
}

## Quads along one edge of each ring.
##
## Vertex count per ring is [code](RING_RESOLUTION + 1)^2[/code], so raising this costs
## quadratically more memory and vertex shading.
const RING_RESOLUTION: int = 96

## Edge length of a single quad in the innermost ring, in metres.
##
## Objects dent the surface in the vertex shader, so this is also the finest wake a
## floating body can carve: a half-metre quad resolves a small boat, a two-metre one turns
## the same hollow into four flat facets.
const BASE_QUAD_SIZE: float = 0.5

## Number of concentric rings.
##
## Each ring doubles the extent of the one inside it, so the surface reaches
## [code]BASE_QUAD_SIZE * RING_RESOLUTION * 2^(RING_COUNT - 1) / 2[/code] metres from the
## viewer in each direction.
const RING_COUNT: int = 8

## How many of the inner rings cast shadows.
##
## Wave crests must cast for god rays to exist at all — see [method _create_ring_instance].
## But a shadow pass re-runs the wave vertex shader over every casting ring, so this is
## kept to the rings that actually fall inside the sun's
## [member DirectionalLight3D.directional_shadow_max_distance]. Rings beyond it would pay a
## full pass to produce shadows the renderer then discards.
##
## Rings 0-3 reach 192 m, which covers the sun's default 160 m shadow distance.
const SHADOW_CASTING_RINGS: int = 4

## Vertical half-extent applied to each ring's culling bounds, in metres.
##
## Waves are displaced on the GPU, so Godot's CPU-side bounds do not reflect where the
## geometry ends up. Padding the AABB stops rings being culled while still on screen; it
## must exceed the tallest wave the spectrum can produce.
const CULL_HEIGHT_PADDING: float = 100.0

## Largest number of object contacts pushed to the shaders in one frame.
##
## [code]ocean.gdshader[/code] declares its contact arrays with this size as a literal, since
## GLSL array sizes must be compile-time constants, so a change here must be made there too.
##
## This is also the foam simulation's limit: [constant FoamField.MAX_CONTACTS] is defined from
## it, because every contact packed here is handed on to [method FoamField.set_contacts].
## [code]foam_sim.gdshader[/code] holds a second literal copy of the size.
const MAX_CONTACTS: int = 8

## How long a reported contact stays live without being renewed, in seconds.
##
## Contacts arrive on the physics clock and are consumed on the render clock, which do not
## tick together. Expiring them on a timer rather than clearing them every frame is what
## stops an object's wake strobing on frames where physics did not run.
const CONTACT_TIMEOUT: float = 0.3

## Wave spectrum shared by the rendered surface, the foam simulation and CPU queries.
##
## Assigning a field subscribes to its [signal Resource.changed] so that edits reach the
## shader immediately, keeping [method get_water_height] in agreement with what is drawn.
@export var wave_field: WaveField:
	set(value):
		if wave_field == value:
			return
		_disconnect_wave_field()
		wave_field = value
		_connect_wave_field()
		_push_wave_parameters()

## Material applied to every ring. Expected to use [code]ocean.gdshader[/code].
@export var material: ShaderMaterial:
	set(value):
		if material == value:
			return
		material = value
		_apply_material()
		_push_wave_parameters()

## Persistent foam simulation. Optional; without one the surface falls back to analytic
## whitecaps, which have no memory and carry no wakes.
@export var foam_field: FoamField

## Node the surface re-centres on. Falls back to the viewport's active camera when unset.
@export var follow_target: Node3D

## Seconds of wave animation elapsed.
##
## Accumulated in [method _process] rather than read from [method Time.get_ticks_msec] so
## that it advances in lockstep with the value pushed to the shader: both respect
## [member Engine.time_scale] and stop while the tree is paused. Wall-clock time would let
## CPU queries drift away from the drawn surface whenever time is scaled or paused.
var elapsed_time: float = 0.0

var _rings: Array[MeshInstance3D] = []
var _contacts: Dictionary = {}
var _impact_sequence: int = 0


func _ready() -> void:
	rebuild()
	_connect_wave_field()


func _process(delta: float) -> void:
	elapsed_time += delta
	_expire_contacts(delta)
	_push_contacts()
	_push_wave_time()
	_recentre_rings()
	_simulate_foam(delta)


func _exit_tree() -> void:
	_disconnect_wave_field()


## Rebuilds the ring meshes and reapplies the material.
##
## Called automatically on ready; only needed afterwards if the LOD constants change.
func rebuild() -> void:
	_build_rings()
	_apply_material()
	_push_wave_parameters()
	surface_rebuilt.emit()


## Returns the global water surface height above [param world_xz].
##
## This is the height of the wave generated at [param world_xz], which is not quite the
## height of the water that has been displaced sideways to sit above it. The difference
## stays well below the wave amplitude; use [method get_surface_point] where it matters.
func get_water_height(world_xz: Vector2) -> float:
	if wave_field == null:
		return global_position.y
	return global_position.y + wave_field.sample_height(world_xz, elapsed_time)


## Returns the surface point above [param world_xz], corrected for horizontal displacement.
##
## Gerstner waves move water sideways as well as vertically, so the surface directly above
## a point was generated somewhere else. This inverts that offset.
func get_surface_point(world_xz: Vector2) -> Vector3:
	if wave_field == null:
		return Vector3(world_xz.x, global_position.y, world_xz.y)
	var point := wave_field.sample_surface_point(world_xz, elapsed_time)
	point.y += global_position.y
	return point


## Returns the unit surface normal above [param world_xz].
func get_water_normal(world_xz: Vector2) -> Vector3:
	if wave_field == null:
		return Vector3.UP
	return wave_field.sample_normal(world_xz, elapsed_time)


## Returns the velocity of the water at [param world_xz], in metres per second.
##
## Includes the orbital motion that carries floating objects forward under a crest and back
## again in the trough, so drag against this is what makes waves push things around rather
## than only lift them.
func get_water_velocity(world_xz: Vector2) -> Vector3:
	if wave_field == null:
		return Vector3.ZERO
	return wave_field.sample_velocity(world_xz, elapsed_time)


## Reports that [param source] is touching the water this frame.
##
## [param radius] is the object's horizontal half-size at the waterline, [param velocity] its
## world velocity, [param relative_velocity] its velocity relative to the water around it,
## and [param submersion] how deep it sits, from 0 (skimming) to 1 (fully under).
##
## The ocean uses these to dent the surface, carve a wake and churn foam; call it every
## physics frame while the object is in the water and stop when it leaves. Contacts expire on
## their own after [constant CONTACT_TIMEOUT], so nothing has to be unregistered.
func report_contact(
	source: Object,
	world_position: Vector3,
	radius: float,
	velocity: Vector3,
	relative_velocity: Vector3,
	submersion: float,
) -> void:
	if source == null:
		return
	_contacts[source.get_instance_id()] = Contact.new(
		world_position,
		radius,
		velocity,
		relative_velocity,
		clampf(submersion, 0.0, 1.0),
		source as Node3D,
	)


## Raises a discrete water impact, forwarding it to [signal water_impacted].
##
## Called by floating bodies when they cross the surface. Effects should connect to the
## signal rather than calling this.
func report_impact(impact: WaterImpact) -> void:
	if impact == null:
		return
	if impact.seed == 0:
		_impact_sequence += 1
		# Position is mixed in so separate oceans do not all begin with the same-looking burst.
		impact.seed = hash(Vector4(
			impact.position.x, impact.position.y, impact.position.z, float(_impact_sequence)
		))
	water_impacted.emit(impact)


## Returns a snapshot of everything currently in the water.
##
## Safe to hold: each call builds fresh [WaterContact] copies, so nothing mutates underneath
## a caller. Intended to be polled on the render clock by continuous effects such as bow
## spray and hull churn — see [WaterContact] for why those are polled rather than signalled.
func get_active_contacts() -> Array[WaterContact]:
	var snapshots: Array[WaterContact] = []
	for id: int in _contacts:
		var contact: Contact = _contacts[id]
		var snapshot := WaterContact.new()
		snapshot.position = contact.position
		snapshot.waterline_radius = contact.radius
		snapshot.relative_velocity = contact.relative_velocity
		snapshot.submersion = contact.submersion
		snapshot.source = contact.source
		snapshots.append(snapshot)
	return snapshots


func _connect_wave_field() -> void:
	if wave_field != null and not wave_field.changed.is_connected(_on_wave_field_changed):
		wave_field.changed.connect(_on_wave_field_changed)


func _disconnect_wave_field() -> void:
	if wave_field != null and wave_field.changed.is_connected(_on_wave_field_changed):
		wave_field.changed.disconnect(_on_wave_field_changed)


func _on_wave_field_changed() -> void:
	_push_wave_parameters()


func _push_wave_parameters() -> void:
	if wave_field != null and material != null:
		wave_field.apply_to_material(material)


## Feeds the CPU clock to the shader so both evaluate the spectrum at the same instant.
func _push_wave_time() -> void:
	if material != null:
		material.set_shader_parameter(&"wave_time", elapsed_time)


## Ages out contacts whose owner has stopped reporting.
func _expire_contacts(delta: float) -> void:
	for id: int in _contacts.keys():
		var contact: Contact = _contacts[id]
		contact.age += delta
		if contact.age > CONTACT_TIMEOUT:
			_contacts.erase(id)


## Packs live contacts into shader uniforms for the surface and the foam simulation.
##
## Three arrays rather than two: the wake needs to know which way an object is travelling
## through the water, and how fast, to lay a directional V behind it instead of a symmetric
## ring. That direction is the object's motion relative to the water, not its world velocity —
## a hull drifting with a current leaves no wake at all.
func _push_contacts() -> void:
	var positions := PackedVector4Array()
	var motion := PackedVector4Array()
	var wake := PackedVector4Array()

	for id: int in _contacts:
		if positions.size() >= MAX_CONTACTS:
			break
		var contact: Contact = _contacts[id]
		positions.append(Vector4(
			contact.position.x, contact.position.y, contact.position.z, contact.radius
		))
		motion.append(Vector4(
			contact.velocity.x, contact.velocity.y, contact.velocity.z, contact.submersion
		))

		# Direction of travel through the water on the XZ plane, with its speed in W. Packed
		# pre-normalised so the shader does not renormalise a near-zero vector per vertex.
		var flat := Vector2(contact.relative_velocity.x, contact.relative_velocity.z)
		var speed := flat.length()
		var heading := flat / speed if speed > 0.001 else Vector2.ZERO
		wake.append(Vector4(heading.x, heading.y, 0.0, speed))

	var count := positions.size()
	# The shader declares fixed-size arrays, so a short one has to be padded or the unused
	# elements keep whatever a busier frame left in them.
	positions.resize(MAX_CONTACTS)
	motion.resize(MAX_CONTACTS)
	wake.resize(MAX_CONTACTS)

	if material != null:
		material.set_shader_parameter(&"contacts", positions)
		material.set_shader_parameter(&"contact_motion", motion)
		material.set_shader_parameter(&"contact_wake", wake)
		material.set_shader_parameter(&"contact_count", count)
	if foam_field != null:
		foam_field.set_contacts(positions, motion, wake)


## Steps the foam simulation and points the surface shader at its output.
func _simulate_foam(delta: float) -> void:
	if foam_field == null or material == null:
		return

	var target := _resolve_follow_target()
	var centre := Vector2.ZERO
	if target != null:
		centre = Vector2(target.global_position.x, target.global_position.z)

	foam_field.simulate(elapsed_time, delta, centre, wave_field)

	var texture := foam_field.get_foam_texture()
	if texture == null:
		return
	material.set_shader_parameter(&"foam_map", texture)
	material.set_shader_parameter(&"foam_map_center", foam_field.get_center())
	material.set_shader_parameter(&"foam_map_extent", foam_field.extent)
	material.set_shader_parameter(&"foam_map_strength", 1.0)


func _build_rings() -> void:
	for ring in _rings:
		if is_instance_valid(ring):
			ring.queue_free()
	_rings.clear()

	for ring_index in RING_COUNT:
		var quad_size := BASE_QUAD_SIZE * pow(2.0, ring_index)
		# The innermost ring is solid; the rest are frames around what it already covers.
		var mesh := (
			_build_grid_mesh(RING_RESOLUTION, quad_size) if ring_index == 0
			else _build_ring_mesh(RING_RESOLUTION, quad_size)
		)
		_rings.append(_create_ring_instance(ring_index, quad_size, mesh))


func _create_ring_instance(ring_index: int, quad_size: float, mesh: Mesh) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = "OceanRing%d" % ring_index
	instance.mesh = mesh
	# Wave crests must cast, or there are no god rays.
	#
	# Shafts are the sun's shadow written into the volumetric fog's froxel grid, so
	# something has to interrupt the light. Over open ocean the only candidate is the water
	# itself: crests shadowing the troughs behind them is what breaks the haze into beams.
	# With casting off the fog can only ever be uniform, however it is tuned.
	#
	# Only the inner rings cast. A shadow pass re-runs the wave vertex shader over the whole
	# ring, and the outer rings are both enormous and far outside
	# directional_shadow_max_distance, so they would cost a full extra pass each and
	# contribute nothing.
	instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON if ring_index < SHADOW_CASTING_RINGS
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)

	var extent := quad_size * RING_RESOLUTION * 0.5
	instance.custom_aabb = AABB(
		Vector3(-extent, -CULL_HEIGHT_PADDING, -extent),
		Vector3(extent * 2.0, CULL_HEIGHT_PADDING * 2.0, extent * 2.0),
	)

	# Deliberately not assigning `owner`: an owned child is serialised into the .tscn when
	# the scene is saved in the editor, which would bake this generated geometry into the
	# file. These meshes are rebuilt from code on every _ready().
	add_child(instance)
	return instance


## Builds a solid grid of [param resolution] squared quads, centred on the origin.
func _build_grid_mesh(resolution: int, quad_size: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half_extent := resolution * quad_size * 0.5

	_append_grid_vertices(vertices, uvs, resolution, quad_size, half_extent)

	var stride := resolution + 1
	for z in resolution:
		for x in resolution:
			_append_quad_indices(indices, z * stride + x, stride)

	return _build_mesh(vertices, uvs, indices)


## Builds a hollow square frame, leaving the middle open for the finer rings inside it.
func _build_ring_mesh(resolution: int, quad_size: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var half_extent := resolution * quad_size * 0.5
	# The hole matches the extent covered by every finer ring combined.
	var hole_extent := half_extent * 0.5

	_append_grid_vertices(vertices, uvs, resolution, quad_size, half_extent)

	var stride := resolution + 1
	for z in resolution:
		for x in resolution:
			var centre_x := (x + 0.5) * quad_size - half_extent
			var centre_z := (z + 0.5) * quad_size - half_extent
			if absf(centre_x) < hole_extent and absf(centre_z) < hole_extent:
				continue
			_append_quad_indices(indices, z * stride + x, stride)

	return _build_mesh(vertices, uvs, indices)


func _append_grid_vertices(
	vertices: PackedVector3Array,
	uvs: PackedVector2Array,
	resolution: int,
	quad_size: float,
	half_extent: float,
) -> void:
	for z in resolution + 1:
		for x in resolution + 1:
			vertices.append(
				Vector3(x * quad_size - half_extent, 0.0, z * quad_size - half_extent)
			)
			uvs.append(Vector2(float(x) / resolution, float(z) / resolution))


## Appends the two triangles of one quad, wound clockwise as seen from above.
##
## Godot treats clockwise faces as front-facing. Reversing this order makes the whole
## surface back-facing, and [code]cull_back[/code] then discards it wherever the waves are
## near flat — which presents as the ocean turning transparent in patches rather than as
## any kind of error.
func _append_quad_indices(indices: PackedInt32Array, corner: int, stride: int) -> void:
	indices.append_array([corner, corner + 1, corner + stride])
	indices.append_array([corner + 1, corner + stride + 1, corner + stride])


func _build_mesh(
	vertices: PackedVector3Array,
	uvs: PackedVector2Array,
	indices: PackedInt32Array,
) -> ArrayMesh:
	var surface_arrays := []
	surface_arrays.resize(Mesh.ARRAY_MAX)
	surface_arrays[Mesh.ARRAY_VERTEX] = vertices
	surface_arrays[Mesh.ARRAY_TEX_UV] = uvs
	surface_arrays[Mesh.ARRAY_INDEX] = indices

	# No normals are stored: the shader derives them analytically from the wave spectrum,
	# which is exact where interpolated vertex normals would only approximate.
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
	return mesh


func _apply_material() -> void:
	for ring in _rings:
		if is_instance_valid(ring):
			ring.material_override = material


## Snaps each ring to the viewer, quantised to that ring's own quad size.
##
## The quantisation is what prevents shimmer: a continuously sliding mesh would have every
## vertex sampling a different point of the wave field each frame, and the surface would
## appear to boil.
func _recentre_rings() -> void:
	var target := _resolve_follow_target()
	if target == null:
		return

	var origin := target.global_position
	for ring_index in _rings.size():
		var ring := _rings[ring_index]
		if not is_instance_valid(ring):
			continue
		var quad_size := BASE_QUAD_SIZE * pow(2.0, ring_index)
		ring.global_position = Vector3(
			snappedf(origin.x, quad_size),
			global_position.y,
			snappedf(origin.z, quad_size),
		)


func _resolve_follow_target() -> Node3D:
	if follow_target != null:
		return follow_target
	return get_viewport().get_camera_3d()


## One object's continuous contact with the water, as reported by [method report_contact].
class Contact:
	extends RefCounted

	var position: Vector3
	var radius: float
	var velocity: Vector3
	## Velocity relative to the water, which is what actually carves a wake.
	var relative_velocity: Vector3
	var submersion: float
	var source: Node3D
	## Seconds since this contact was last renewed. See [constant Ocean.CONTACT_TIMEOUT].
	var age: float = 0.0

	func _init(
		contact_position: Vector3,
		contact_radius: float,
		contact_velocity: Vector3,
		contact_relative_velocity: Vector3,
		contact_submersion: float,
		contact_source: Node3D,
	) -> void:
		position = contact_position
		radius = contact_radius
		velocity = contact_velocity
		relative_velocity = contact_relative_velocity
		submersion = contact_submersion
		source = contact_source

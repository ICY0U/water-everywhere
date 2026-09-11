class_name FoamField
extends Node3D

## A persistent foam simulation held in a world-space texture that follows the viewer.
##
## Foam is the part of water that most obviously has a memory. A crest breaks, throws white
## water, and leaves a streak that drifts downwind and dissolves over several seconds; a
## boat leaves a wake behind it, not around it. None of that can be derived from the wave
## field's current state, because none of it depends only on the present — so it is
## simulated instead, one texel per patch of sea, and only the result is handed to
## [code]ocean.gdshader[/code].
##
## The simulation is a ping-pong pair of [SubViewport]s: each frame one of them renders
## [code]foam_sim.gdshader[/code] while reading the other, then they swap. The pair exists
## because a shader cannot read the texture it is writing; alternating between two removes
## the hazard without a copy.
##
## Nothing drives this node on its own. [Ocean] owns the wave clock and calls
## [method simulate] once per frame, so the foam, the rendered surface and CPU-side wave
## queries all evaluate the spectrum at exactly the same instant.

## Emitted after the buffers have been rebuilt by [method rebuild].
signal buffers_rebuilt

## Largest number of object contacts the simulation shader accepts.
##
## Must match the array size declared in [code]foam_sim.gdshader[/code].
const MAX_CONTACTS: int = 8

## Longest simulation step accepted, in seconds.
##
## A frame hitch would otherwise advect and decay the whole map in one jump, which is
## visible as the foam blinking out. Clamping trades a moment of slow-motion foam for not
## losing the map.
const MAX_STEP: float = 0.1

## Simulation material, expected to use [code]foam_sim.gdshader[/code].
##
## Duplicated once per buffer on ready, so foam parameters can be authored on a single
## material in the inspector while each buffer still points at the other one's texture.
@export var material: ShaderMaterial:
	set(value):
		if material == value:
			return
		material = value
		if is_inside_tree():
			rebuild()

## Width and height of the simulation texture, in texels.
##
## Together with [member extent] this sets how fine foam can be: the default covers 192 m
## with 512 texels, or 37 cm each. Detail finer than that is added by the noise in the
## ocean shader rather than by simulating it.
@export_range(64, 2048, 64) var resolution: int = 512:
	set(value):
		if resolution == value:
			return
		resolution = value
		if is_inside_tree():
			rebuild()

## Half-width of the sea area simulated, in metres.
@export_range(8.0, 1000.0, 1.0) var extent: float = 96.0

## Fraction of the wind speed at which foam drifts downwind.
##
## Stokes drift moves floating matter at roughly 2–3% of the wind speed. It is what lines
## foam streaks up with the wind instead of leaving them where they were made.
@export_range(0.0, 0.2, 0.001) var drift_fraction: float = 0.025

var _buffers: Array[SubViewport] = []
var _materials: Array[ShaderMaterial] = []
var _read_index: int = 0
var _center: Vector2 = Vector2.ZERO
var _previous_center: Vector2 = Vector2.ZERO
var _contacts: PackedVector4Array = PackedVector4Array()
var _contact_motion: PackedVector4Array = PackedVector4Array()
var _contact_wake: PackedVector4Array = PackedVector4Array()
var _contact_count: int = 0


func _ready() -> void:
	rebuild()


## Rebuilds both simulation buffers and their materials.
func rebuild() -> void:
	for buffer in _buffers:
		if is_instance_valid(buffer):
			buffer.queue_free()
	_buffers.clear()
	_materials.clear()
	_read_index = 0

	if material == null:
		push_warning("%s: no simulation material assigned; foam will not run." % name)
		return

	for index in 2:
		var buffer := _create_buffer(index)
		_buffers.append(buffer)
		_materials.append(buffer.get_child(0).material as ShaderMaterial)

	# Each buffer reads the other. Linked after both exist, because neither texture is
	# available until its viewport is in the tree.
	_materials[0].set_shader_parameter(&"previous_map", _buffers[1].get_texture())
	_materials[1].set_shader_parameter(&"previous_map", _buffers[0].get_texture())

	buffers_rebuilt.emit()


## Advances the simulation one step, centred on [param center] in world XZ.
##
## [param wave_time] must be the same clock the ocean surface is drawn with, or foam will
## appear where waves are not breaking. [param delta] is clamped to [constant MAX_STEP].
func simulate(wave_time: float, delta: float, center: Vector2, field: WaveField) -> void:
	if _materials.size() < 2:
		return

	# Snapping the window to whole texels makes the frame-to-frame reprojection an exact
	# integer shift. Without it every frame resamples the whole map through a bilinear
	# filter and the foam smears itself into mush within a few seconds of camera motion.
	_center = center.snappedf(texel_size())

	var write_index := 1 - _read_index
	var write_material := _materials[write_index]

	if field != null:
		field.apply_to_material(write_material)
		write_material.set_shader_parameter(&"foam_drift", _drift_velocity(field))
	write_material.set_shader_parameter(&"wave_time", wave_time)
	write_material.set_shader_parameter(&"sim_delta", minf(delta, MAX_STEP))
	write_material.set_shader_parameter(&"sim_center", _center)
	write_material.set_shader_parameter(&"previous_center", _previous_center)
	write_material.set_shader_parameter(&"sim_extent", extent)
	write_material.set_shader_parameter(&"contacts", _contacts)
	write_material.set_shader_parameter(&"contact_motion", _contact_motion)
	write_material.set_shader_parameter(&"contact_wake", _contact_wake)
	write_material.set_shader_parameter(&"contact_count", _contact_count)

	# SubViewports are drawn before the viewport that samples them, so the buffer requested
	# here is already current by the time the ocean renders this frame. That is why the
	# swap happens now rather than next frame.
	_buffers[write_index].render_target_update_mode = SubViewport.UPDATE_ONCE
	_previous_center = _center
	_read_index = write_index


## Replaces the object contacts fed to the simulation. Excess contacts are dropped.
##
## [param positions] carry the world position in XYZ and the contact radius in W;
## [param motion] carries world velocity in XYZ and how submerged the object is in W;
## [param wake] carries the unit direction of travel through the water in XY and the speed
## along it in W, which is what lets foam be laid down the wake instead of in a ring.
func set_contacts(
	positions: PackedVector4Array, motion: PackedVector4Array, wake: PackedVector4Array
) -> void:
	_contact_count = mini(positions.size(), MAX_CONTACTS)
	_contacts = positions.slice(0, _contact_count)
	_contact_motion = motion.slice(0, _contact_count)
	_contact_wake = wake.slice(0, _contact_count)
	# The shader declares fixed-size arrays, so short ones have to be padded or the
	# remaining elements keep whatever the last longer frame left in them.
	_contacts.resize(MAX_CONTACTS)
	_contact_motion.resize(MAX_CONTACTS)
	_contact_wake.resize(MAX_CONTACTS)


## Returns the texture holding the current foam state, for the ocean shader to sample.
##
## R is actively breaking foam, G is the residue it leaves behind.
func get_foam_texture() -> Texture2D:
	if _buffers.size() < 2:
		return null
	return _buffers[_read_index].get_texture()


## Returns the world XZ the simulated window is currently centred on.
##
## Snapped to whole texels by [method simulate], so it is not exactly the centre that was
## requested; the ocean shader must use this value to locate the map, not its own idea of
## where the viewer is.
func get_center() -> Vector2:
	return _center


## Returns the size of one simulation texel, in metres.
func texel_size() -> float:
	return 2.0 * extent / float(maxi(resolution, 1))


## Writes one simulation parameter to both buffers and to the template material.
##
## The buffers run on duplicates of [member material], so writing to the template alone
## would only take effect after the next [method rebuild]. Weather changes foam behaviour
## while the simulation is running, so it goes through here.
func set_simulation_parameter(parameter: StringName, value: Variant) -> void:
	if material != null:
		material.set_shader_parameter(parameter, value)
	for buffer_material in _materials:
		buffer_material.set_shader_parameter(parameter, value)


func _create_buffer(index: int) -> SubViewport:
	var buffer := SubViewport.new()
	buffer.name = "FoamBuffer%d" % index
	buffer.size = Vector2i(resolution, resolution)
	buffer.disable_3d = true
	buffer.transparent_bg = false
	# Half-float precision. Foam is accumulated and decayed every frame, so 8-bit
	# quantisation shows up as banded steps in the fade rather than a smooth dissolve.
	buffer.use_hdr_2d = true
	buffer.render_target_update_mode = SubViewport.UPDATE_DISABLED
	buffer.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS

	var surface := ColorRect.new()
	surface.name = "Simulation"
	surface.size = Vector2(resolution, resolution)
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.material = material.duplicate() as ShaderMaterial
	buffer.add_child(surface)

	# Deliberately not assigning `owner`: an owned child is serialised into the .tscn when
	# the scene is saved in the editor, baking these generated buffers into the file.
	add_child(buffer)
	return buffer


## Returns the surface drift velocity in world XZ, in metres per second.
func _drift_velocity(field: WaveField) -> Vector2:
	var heading := deg_to_rad(field.wind_angle)
	return Vector2(cos(heading), sin(heading)) * field.wind_speed * drift_fraction

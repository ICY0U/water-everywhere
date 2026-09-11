class_name OceanParticles
extends Node3D

## Base for particle effects that live on the ocean: anything launched from the water,
## falling onto it, or riding on it.
##
## The particles are simulated on the GPU, where they cannot ask [Ocean] where the surface
## is. So every process material here includes [code]gerstner_waves.gdshaderinc[/code] and is
## kept in step with the sea exactly as the ocean's own material is: the spectrum is written
## by [method WaveField.apply_to_material] whenever the sea state changes, and the ocean's
## clock is pushed every frame. A droplet therefore lands on the wave that is actually drawn
## rather than on a flat plane at sea level, and a ripple ring rides the swell it fell on.
##
## The node follows the viewer at sea level. Its emitters run in world space, so particles
## stay where they were launched as the viewer moves on; only where new ones start follows.
##
## Subclasses create their emitters in [method _build_emitters] using
## [method _create_emitter] and [method _create_ripples], and follow the sea and the weather
## by overriding [method _sea_state_changed] and [method _weather_changed].

## Height of the region particles are culled against, above and below sea level, in metres.
##
## An emitter's bounds cannot be measured from particles simulated on the GPU, so this is a
## deliberate over-estimate: too small a box culls a system while it is plainly on screen.
const VISIBILITY_HEIGHT: float = 150.0

## Process shader for the ripple rings every effect leaves where its particles land.
const RIPPLE_PROCESS_SHADER: Shader = preload("res://shaders/ripple_particles.gdshader")

## Draw shader for those rings.
const RIPPLE_DRAW_SHADER: Shader = preload("res://shaders/ripple_ring.gdshader")

## Ocean the particles launch from and land on. Required.
@export var ocean: Ocean

## Weather that drives the effect. Optional; without it the effect keeps its defaults.
@export var weather: WeatherController

## Node the emitters follow. Falls back to the viewport's active camera when unset.
@export var follow_target: Node3D

@export_group("Ripples")

## Colour of the rings left where particles land.
##
## Close to the water rather than to the foam: a ring is disturbed water catching the light,
## and painting it white makes every landing read as a splash of foam.
@export var ripple_color: Color = Color(0.76, 0.85, 0.9)

## Rings in each ripple. A real drop leaves a short train of them.
@export_range(1, 4, 1) var ripple_ring_count: int = 2

var _process_materials: Array[ShaderMaterial] = []
var _connected_field: WaveField


func _ready() -> void:
	if ocean == null:
		push_warning("%s: no ocean assigned; the effect is disabled." % name)
		return

	# Processed after the ocean, whose _process advances the wave clock pushed from here.
	# Otherwise the particles would test for landing against last frame's sea.
	process_priority = ocean.process_priority + 1

	_build_emitters()
	_connect_sea_state()
	_on_sea_state_changed()

	if weather != null:
		weather.weather_changed.connect(_on_weather_changed)
		# The controller applies its first preset in its own _ready, possibly before this
		# node was ready to hear about it.
		var preset := weather.current_preset()
		if preset != null:
			_weather_changed(preset)


func _process(_delta: float) -> void:
	if ocean == null:
		return

	var viewer := _resolve_viewer_position()
	global_position = Vector3(viewer.x, ocean.global_position.y, viewer.z)

	# Every process material gets the same per-frame state. The ripple shader declares no
	# viewer_position; a ShaderMaterial just holds a value its shader does not use.
	for process_material in _process_materials:
		process_material.set_shader_parameter(&"wave_time", ocean.elapsed_time)
		process_material.set_shader_parameter(&"sea_level", ocean.global_position.y)
		process_material.set_shader_parameter(&"viewer_position", viewer)


func _exit_tree() -> void:
	_disconnect_sea_state()
	if weather != null and weather.weather_changed.is_connected(_on_weather_changed):
		weather.weather_changed.disconnect(_on_weather_changed)


## Creates this effect's emitters. Called once, on ready. Override in subclasses.
func _build_emitters() -> void:
	pass


## Called when the ocean's [WaveField] changes, after the new spectrum has reached every
## process material. Override to derive anything else from the sea state.
func _sea_state_changed(_field: WaveField) -> void:
	pass


## Called when [member weather] applies a preset, and once on ready. Override to follow it.
func _weather_changed(_preset: WeatherPreset) -> void:
	pass


## Creates a world-space emitter driven by [param process_shader] and adds it as a child.
##
## [param cycle] becomes the emitter's lifetime. Each particle slot restarts once per cycle,
## so it must cover the longest life any particle is given. [param half_extent] is how far
## the effect reaches horizontally from this node, and sets the culling bounds.
func _create_emitter(
	emitter_name: String,
	amount: int,
	cycle: float,
	process_shader: Shader,
	draw_mesh: Mesh,
	draw_material: Material,
	half_extent: float,
) -> GPUParticles3D:
	var process_material := ShaderMaterial.new()
	process_material.shader = process_shader
	_process_materials.append(process_material)

	var emitter := GPUParticles3D.new()
	emitter.name = emitter_name
	emitter.amount = amount
	emitter.lifetime = cycle
	# World space: a droplet stays where it was thrown as the viewer moves on.
	emitter.local_coords = false
	# Stepped every rendered frame rather than at the default fixed 30 Hz. Ripple rings are
	# re-placed on the moving surface each step, and at 30 Hz the ocean, which moves every
	# frame, visibly slides about underneath them.
	emitter.fixed_fps = 0
	emitter.interpolate = false
	emitter.process_material = process_material
	emitter.draw_pass_1 = draw_mesh
	emitter.material_override = draw_material
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	emitter.visibility_aabb = AABB(
		Vector3(-half_extent, -VISIBILITY_HEIGHT, -half_extent),
		Vector3(half_extent * 2.0, VISIBILITY_HEIGHT * 2.0, half_extent * 2.0),
	)

	# Deliberately not assigning `owner`: an owned child is serialised into the .tscn when the
	# scene is saved in the editor, and these are rebuilt from code on every _ready().
	add_child(emitter)
	return emitter


## Creates the ripple rings [param emitter]'s particles leave where they land, and makes it
## that emitter's sub-emitter.
##
## [param amount] caps how many rings exist at once; landings beyond it simply leave none.
## [param longest_life] must cover the longest ring lifetime the emitter asks for.
func _create_ripples(
	emitter: GPUParticles3D,
	amount: int,
	longest_life: float,
) -> GPUParticles3D:
	var draw_material := ShaderMaterial.new()
	draw_material.shader = RIPPLE_DRAW_SHADER
	draw_material.set_shader_parameter(&"albedo", ripple_color)
	draw_material.set_shader_parameter(&"ring_count", ripple_ring_count)

	var ripples := _create_emitter(
		"%sRipples" % emitter.name,
		amount,
		longest_life,
		RIPPLE_PROCESS_SHADER,
		PlaneMesh.new(),
		draw_material,
		emitter.visibility_aabb.size.x * 0.5,
	)
	emitter.sub_emitter = emitter.get_path_to(ripples)
	return ripples


func _connect_sea_state() -> void:
	_connected_field = ocean.wave_field
	if _connected_field != null and not _connected_field.changed.is_connected(
		_on_sea_state_changed
	):
		_connected_field.changed.connect(_on_sea_state_changed)


func _disconnect_sea_state() -> void:
	if _connected_field != null and _connected_field.changed.is_connected(
		_on_sea_state_changed
	):
		_connected_field.changed.disconnect(_on_sea_state_changed)
	_connected_field = null


## Writes the current spectrum to every process material, then lets the subclass follow.
func _on_sea_state_changed() -> void:
	if ocean == null or ocean.wave_field == null:
		return
	var field := ocean.wave_field
	for process_material in _process_materials:
		field.apply_to_material(process_material)
		# Not part of the spectrum, so apply_to_material() does not carry it; the particles
		# need it for the air they fly through.
		process_material.set_shader_parameter(&"wind_speed", field.wind_speed)
	_sea_state_changed(field)


func _on_weather_changed(preset: WeatherPreset, _index: int) -> void:
	_weather_changed(preset)


func _resolve_viewer_position() -> Vector3:
	var target: Node3D = follow_target
	if target == null:
		target = get_viewport().get_camera_3d()
	if target == null:
		return global_position
	return target.global_position

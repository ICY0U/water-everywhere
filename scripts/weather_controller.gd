class_name WeatherController
extends Node

## Applies [WeatherPreset] resources to the scene and cycles between them.
##
## Owns the wiring between a preset and the four things it drives — sky material,
## environment, sun and ocean — so nothing else in the scene needs to know which nodes a
## weather change touches.
##
## Presets are discrete: switching is instantaneous by design. See [WeatherPreset].

## Emitted after a preset is applied, carrying the preset and its index.
signal weather_changed(preset: WeatherPreset, index: int)

## Weather looks to cycle through, in order.
@export var presets: Array[WeatherPreset] = []

## Preset applied on ready.
@export var starting_index: int = 0

@export_group("Targets")

## Environment holding the sky whose material is driven. Required for any visible change.
@export var world_environment: WorldEnvironment

## Sun the sky shader reads as LIGHT0 and the scene lights from.
@export var sun: DirectionalLight3D

## Ocean whose colours, sea state and foam follow the weather.
@export var ocean: Ocean

## Atmosphere whose fog and god rays follow the weather. Optional: without it the scene
## still changes sky, sun and water, just with no change in the air.
@export var atmosphere: Atmosphere

var _current_index: int = -1


func _process(_delta: float) -> void:
	# Sky shaders cannot read the ocean's custom clock directly. Pushing it here keeps cloud
	# animation on the same replicated timeline as waves, foam and particle landings.
	if ocean == null:
		return
	var sky_material := _resolve_sky_material()
	if sky_material != null:
		sky_material.set_shader_parameter(&"weather_time", ocean.elapsed_time)


func _ready() -> void:
	if presets.is_empty():
		push_warning("%s: no weather presets assigned." % name)
		return
	apply_index(starting_index)


## Applies the preset at [param index], wrapping around the ends of the list.
func apply_index(index: int) -> void:
	if presets.is_empty():
		return

	var wrapped := posmod(index, presets.size())
	var preset := presets[wrapped]
	if preset == null:
		push_warning("%s: preset at index %d is empty." % [name, wrapped])
		return

	_current_index = wrapped
	preset.apply(
		_resolve_sky_material(),
		_resolve_environment(),
		sun,
		_resolve_ocean_material(),
		ocean.wave_field if ocean != null else null,
		atmosphere,
		ocean.foam_field if ocean != null else null,
	)
	weather_changed.emit(preset, wrapped)


## Advances to the next preset, wrapping at the end.
func next() -> void:
	apply_index(_current_index + 1)


## Returns to the previous preset, wrapping at the start.
func previous() -> void:
	apply_index(_current_index - 1)


## Returns the index of the preset currently applied, or -1 before the first apply.
##
## The network layer sends this to a joining peer so it starts on the sea everyone else is
## already sailing, rather than on [member starting_index].
func current_index() -> int:
	return _current_index


## Returns the preset currently applied, or null before the first apply.
func current_preset() -> WeatherPreset:
	if _current_index < 0 or _current_index >= presets.size():
		return null
	return presets[_current_index]


func _resolve_environment() -> Environment:
	if world_environment == null:
		return null
	return world_environment.environment


func _resolve_sky_material() -> ShaderMaterial:
	var environment := _resolve_environment()
	if environment == null or environment.sky == null:
		return null
	return environment.sky.sky_material as ShaderMaterial


func _resolve_ocean_material() -> ShaderMaterial:
	if ocean == null:
		return null
	return ocean.material

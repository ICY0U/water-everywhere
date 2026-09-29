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

## Direction the wind blows TOWARD for this scene, in degrees, or negative to keep each preset's.
##
## The presets are shared between scenes, and a direction that suits one layout can work against
## another. Every preset blows toward 45 degrees, which in the voyage is a head sea: the crossing
## runs west, so the crew paddled into the waves while Stokes drift carried them back toward the
## island they left. Overriding the direction here rather than editing the presets leaves every
## other scene's sea exactly as it was.
##
## Applied to a copy of the preset, never to the shared resource, and before anything reads it,
## so the waves, foam, spray, rain, clouds and cloud shadows all agree on the one direction.
## Every peer loads the same scene and therefore applies the same override, so nothing about it
## needs replicating beyond the preset index that already is.
@export_range(-1.0, 360.0, 1.0) var wind_angle_override: float = -1.0

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

## Copies of the presets with [member wind_angle_override] applied, by index. Made once each.
var _overridden: Dictionary = {}


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
	var preset := _effective_preset(wrapped)
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
##
## This is the preset as applied, [member wind_angle_override] included, so anything reading the
## wind from it agrees with the sea that is actually on screen.
func current_preset() -> WeatherPreset:
	if _current_index < 0 or _current_index >= presets.size():
		return null
	return _effective_preset(_current_index)


## Returns the preset at [param index] as this scene applies it.
func _effective_preset(index: int) -> WeatherPreset:
	var preset := presets[index]
	if preset == null or wind_angle_override < 0.0:
		return preset
	if not _overridden.has(index):
		var copy := preset.duplicate() as WeatherPreset
		copy.wind_angle = wind_angle_override
		_overridden[index] = copy
	return _overridden[index]


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

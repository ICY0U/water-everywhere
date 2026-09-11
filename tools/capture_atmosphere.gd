extends Node

## Renders each weather preset framed toward the sun, where god rays are visible.
##
## The existing [code]capture_weather.gd[/code] frames away from the sun to show the sky
## and water, which is exactly the framing in which shafts do not appear: volumetric
## scattering is strongly forward-biased, so the fog only flares when looking [i]into[/i]
## the light. Verifying the atmosphere needs its own framings.
##
## Register it temporarily rather than committing it to [code]project.godot[/code]:
## [codeblock lang=text]
## [autoload]
## AtmosphereShotter="*res://tools/capture_atmosphere.gd"
## [/codeblock]
## Images land in [code]user://shots/[/code].

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "user://shots"

## Frames to wait before the first capture, so shaders have compiled.
const WARMUP_FRAMES: int = 90

## Frames to wait after switching preset or framing.
##
## Volumetric fog uses temporal reprojection, so it accumulates over several frames. Too
## short a settle captures a half-converged, noisy grid rather than the real look.
const SETTLE_FRAMES: int = 30

## Camera framings. Rotations are Euler angles in degrees.
##
## A DirectionalLight3D shines along its local -Z, so a preset azimuth of 150 puts the sun
## at camera yaw -30, not 150. Facing 150 looks directly AWAY from it, which is the one
## framing where forward-scattered shafts cannot appear.
const FRAMINGS: Array[Dictionary] = [
	{
		"name": "into_sun",
		"position": Vector3(0.0, 8.0, 0.0),
		"rotation": Vector3(12.0, -30.0, 0.0),
	},
	{
		"name": "sun_high",
		"position": Vector3(0.0, 14.0, 0.0),
		"rotation": Vector3(34.0, -30.0, 0.0),
	},
	{
		"name": "away",
		"position": Vector3(0.0, 8.0, 0.0),
		"rotation": Vector3(-2.0, 150.0, 0.0),
	},
]

var _weather: WeatherController
var _camera: Camera3D
var _preset_index: int = 0
var _framing_index: int = 0
var _frames_waited: int = 0
var _warmed_up: bool = false


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIRECTORY)

	var tree_root := get_tree().root
	_camera = tree_root.get_camera_3d()
	_weather = tree_root.find_child("Weather", true, false) as WeatherController

	if _camera == null or _weather == null:
		printerr("capture_atmosphere: need both a Camera3D and a WeatherController")
		get_tree().quit(1)
		return

	# The free camera drives its own transform every frame, which would undo the framing.
	if _camera.get_script() != null:
		_camera.set_script(null)

	_apply_state()


func _process(_delta: float) -> void:
	_frames_waited += 1

	if not _warmed_up:
		if _frames_waited < WARMUP_FRAMES:
			return
		_warmed_up = true
		_frames_waited = 0
		return

	if _frames_waited < SETTLE_FRAMES:
		return

	_capture()
	_advance()


func _apply_state() -> void:
	if _weather.presets.is_empty():
		printerr("capture_atmosphere: no presets to capture")
		get_tree().quit(1)
		return

	_weather.apply_index(_preset_index)

	var framing: Dictionary = FRAMINGS[_framing_index]
	_camera.position = framing["position"] as Vector3
	var euler := framing["rotation"] as Vector3
	_camera.rotation = Vector3(
		deg_to_rad(euler.x), deg_to_rad(euler.y), deg_to_rad(euler.z))

	_frames_waited = 0


func _capture() -> void:
	var preset := _weather.presets[_preset_index]
	var preset_name := preset.display_name.to_snake_case() if preset != null else "unknown"
	var framing_name := FRAMINGS[_framing_index]["name"] as String

	var image := get_viewport().get_texture().get_image()
	var path := "%s/atmos_%s_%s.png" % [OUTPUT_DIRECTORY, preset_name, framing_name]
	var error := image.save_png(path)
	if error != OK:
		printerr("capture_atmosphere: could not write %s (error %d)" % [path, error])
	else:
		print("captured %s" % path)


func _advance() -> void:
	_framing_index += 1
	if _framing_index >= FRAMINGS.size():
		_framing_index = 0
		_preset_index += 1

	if _preset_index >= _weather.presets.size():
		print("capture_atmosphere: done")
		get_tree().quit()
		return

	_apply_state()

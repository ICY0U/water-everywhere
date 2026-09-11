extends Node

## Renders every weather preset from two framings, for reviewing the sky without a display.
##
## Registered as an autoload so it runs inside the real rendered scene. For each preset it
## applies the weather, waits for the sky to settle, and captures each framing in turn.
##
## Register it temporarily rather than committing it to [code]project.godot[/code]:
## [codeblock lang=text]
## [autoload]
## WeatherShotter="*res://tools/capture_weather.gd"
## [/codeblock]
## Images land in [code]user://shots/[/code].

## Directory the images are written to.
const OUTPUT_DIRECTORY: String = "user://shots"

## Frames to wait before the first capture, so shaders have compiled.
const WARMUP_FRAMES: int = 90

## Frames to wait after switching preset or framing.
##
## The sky shader is cheap to re-evaluate, but the radiance cubemap it feeds needs a few
## frames to reconverge after the weather changes.
const SETTLE_FRAMES: int = 12

## Camera framings captured for every preset. Rotations are Euler angles in degrees.
const FRAMINGS: Array[Dictionary] = [
	{
		"name": "horizon",
		"position": Vector3(0.0, 6.0, 0.0),
		"rotation": Vector3(-4.0, 25.0, 0.0),
	},
	{
		"name": "sky",
		"position": Vector3(0.0, 12.0, 0.0),
		"rotation": Vector3(22.0, 25.0, 0.0),
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
		printerr("capture_weather: need both a Camera3D and a WeatherController")
		get_tree().quit(1)
		return

	_camera.set_process(false)
	_camera.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	_weather.apply_index(_preset_index)
	_apply_framing()


func _process(_delta: float) -> void:
	# Re-assert every frame: other scripts also write to the camera transform, so setting it
	# once leaves the framing dependent on script execution order.
	_apply_framing()

	_frames_waited += 1
	var required := WARMUP_FRAMES if not _warmed_up else SETTLE_FRAMES
	if _frames_waited < required:
		return
	_warmed_up = true

	await RenderingServer.frame_post_draw
	_save_shot()
	_advance()


func _apply_framing() -> void:
	var framing: Dictionary = FRAMINGS[_framing_index]
	_camera.global_position = framing["position"]
	var degrees: Vector3 = framing["rotation"]
	_camera.global_rotation = Vector3(
		deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z)
	)


func _save_shot() -> void:
	var preset := _weather.current_preset()
	var preset_name := preset.display_name.to_lower() if preset != null else "unknown"
	var framing: Dictionary = FRAMINGS[_framing_index]
	var path := "%s/weather_%s_%s.png" % [OUTPUT_DIRECTORY, preset_name, framing["name"]]

	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		printerr("capture_weather: failed to save %s (error %d)" % [path, error])
	else:
		print("wrote ", ProjectSettings.globalize_path(path))


func _advance() -> void:
	_frames_waited = 0

	_framing_index += 1
	if _framing_index < FRAMINGS.size():
		_apply_framing()
		return

	_framing_index = 0
	_preset_index += 1
	if _preset_index >= _weather.presets.size():
		# Stop processing before quitting: _process runs again before the tree tears down.
		set_process(false)
		get_tree().quit(0)
		return

	_weather.apply_index(_preset_index)
	_apply_framing()
